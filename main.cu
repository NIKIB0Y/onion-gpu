// onion-gpu -- GPU-accelerated Tor v3 vanity .onion address generator.
//
// See README.md for the algorithm, the cost model and the security notes.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <math.h>
#include <errno.h>
#include <signal.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/random.h>
#include <sys/mman.h>
#include <cuda_runtime.h>

#include "sha512.cuh"
#include "sha3_256.cuh"
#include "fe25519.cuh"
#include "ge25519.cuh"

#ifndef THREADS_PER_BLOCK
#define THREADS_PER_BLOCK 128
#endif
#ifndef BLOCKS
#define BLOCKS            512
#endif
#ifndef INNER_BATCH
#define INNER_BATCH       16896  // keys per thread per launch (44 * BINV_N)
#endif
#ifndef BINV_N
#define BINV_N            384    // keys per batch Z-inversion
#endif
#ifndef MIN_BLOCKS_PER_SM
#define MIN_BLOCKS_PER_SM 3
#endif
#define TOTAL_THREADS     (THREADS_PER_BLOCK * BLOCKS)
#define MAX_SLOTS         256    // results captured per launch

// The fast path compares the top bits of one 64-bit word, so it covers
// floor(64/5) address characters exactly.  Longer prefixes fall through to the
// full check in handle_candidate().
#ifndef FAST_CHARS
#define FAST_CHARS        12
#endif

#define CUDA_CHECK(call)                                                      \
    do {                                                                      \
        cudaError_t _e = (call);                                              \
        if (_e != cudaSuccess) {                                              \
            fprintf(stderr, "CUDA error at %s:%d: %s\n",                      \
                    __FILE__, __LINE__, cudaGetErrorString(_e));              \
            exit(1);                                                          \
        }                                                                     \
    } while (0)

static volatile sig_atomic_t g_stop = 0;
static void handle_sigint(int s) { (void)s; g_stop = 1; }

// -------------------------------------------------------------------------
// Device-side constants, refreshed from the host
// -------------------------------------------------------------------------
__constant__ ge_cached c_step;      // 8 * BasePoint, cached affine form
__constant__ uint8_t   c_root[32];  // fresh CSPRNG root, one per launch
__constant__ char      c_prefix[64];

__device__ ge_cached d_step_out;    // init_step_kernel -> host -> c_step

__global__ void init_step_kernel() {
    if (threadIdx.x || blockIdx.x) return;
    uint8_t sc[32] = {0};
    sc[0] = 8;
    ge_p3 S;
    ge_scalarmult_base(&S, sc);
    ge_cached_from_p3(&d_step_out, &S);
}

// -------------------------------------------------------------------------
// Base32 (RFC 4648, lowercase a-z2-7), MSB-first over the byte stream
// -------------------------------------------------------------------------
__device__ void base32_encode(const uint8_t in[35], char out[57]) {
    for (int i = 0; i < 56; i++) {
        int bit_start = i * 5;
        int byte_idx  = bit_start / 8;
        int bit_off   = bit_start % 8;
        uint32_t val;
        if (bit_off <= 3) {
            val = (in[byte_idx] >> (3 - bit_off)) & 0x1f;
        } else {
            val = ((in[byte_idx] << (bit_off - 3)) | (in[byte_idx+1] >> (11 - bit_off))) & 0x1f;
        }
        out[i] = (val < 26) ? (char)('a' + val) : (char)('2' + (val - 26));
    }
    out[56] = '\0';
}

__device__ void clamp_scalar(uint8_t scalar[32], const uint8_t h64[64]) {
    for (int i = 0; i < 32; i++) scalar[i] = h64[i];
    scalar[0]  &= 248;
    scalar[31] &= 127;
    scalar[31] |= 64;
}

// scalar = sc + n, little-endian 256-bit.  The search uses n = 8*index with
// index < INNER_BATCH, so n < 2^18 at the default settings; the carry chain
// below is correct for any uint32_t.
__device__ void scalar_add_small(uint8_t out[32], const uint8_t sc[32], uint32_t n) {
    uint32_t carry = 0;
    for (int i = 0; i < 32; i++) {
        uint32_t b = (i < 4) ? ((n >> (8*i)) & 0xff) : 0;
        uint32_t s = (uint32_t)sc[i] + b + carry;
        out[i] = (uint8_t)(s & 0xff);
        carry = s >> 8;
    }
}

// Tor re-clamps the scalar when it loads hs_ed25519_secret_key, so a scalar
// that is not already in clamped form would be silently altered and would no
// longer match the published address.  sc is clamped and the step is a
// multiple of 8, so only a carry out of bit 254 could break this -- about
// 2^-240 per thread.  Refuse such a key instead of writing a broken one.
__device__ __forceinline__ bool scalar_is_clamped(const uint8_t s[32]) {
    return (s[0] & 7) == 0 && (s[31] & 0xc0) == 0x40;
}

__device__ bool prefix_matches(const char *addr, const char *prefix, int plen) {
    for (int i = 0; i < plen; i++) {
        char a = addr[i], b = prefix[i];
        if (a >= 'A' && a <= 'Z') a += 32;
        if (b >= 'A' && b <= 'Z') b += 32;
        if (a != b) return false;
    }
    return true;
}

// -------------------------------------------------------------------------
// Result buffers
// -------------------------------------------------------------------------
struct Result {
    uint8_t pubkey[32];
    uint8_t scalar[32];   // clamped scalar, exactly as written to the key file
    uint8_t nonce[32];    // second half of the Tor expanded secret key
    char    address[57];
    char    _pad[7];
};

struct Shared {
    unsigned int stored;  // slots claimed (may exceed MAX_SLOTS)
    unsigned int hits;    // full prefix matches seen
    unsigned int fault;   // set if the chain disagreed with scalar multiplication
};

// -------------------------------------------------------------------------
// One batch of BINV_N keys: the incremental chain, a single inversion, and the
// per-key affine y.
//
// Montgomery's trick, fused into the chain.  With prefix_j = Z_0*...*Z_j and
// W_j = Y_j * prefix_{j-1} stored instead of Y_j, the backward pass needs only
//     y_k = W_k * inv   where inv = 1/prefix_k,   then inv *= Z_k
// because W_k/prefix_k = Y_k*prefix_{k-1}/prefix_k = Y_k/Z_k.  That folds the
// forward product into the values already being stored: two arrays instead of
// four, 160 bytes of local traffic per key instead of ~400, at the same four
// multiplies per key for the inversion machinery.
//
// Per-key cost: 7 (chain) + 2 (W, prefix) + 2 (y, inv) = 11 muls, plus one
// fe_invert amortised over BINV_N keys (~1 mul at N=256) = ~12 muls/key.
//
// sink(k, y) receives each affine y.  Templated so the search kernel and the
// differential self-test run byte-for-byte the same arithmetic.
// -------------------------------------------------------------------------
template <typename Sink>
__device__ __forceinline__ void run_batch(ge_p3 *P, fe *Wsave, fe *Zsave,
                                          int batch, Sink sink) {
    fe prefix;
    fe_1(prefix);

    // #pragma unroll 1 keeps j a runtime index so Wsave/Zsave stay in local
    // memory instead of consuming ~200 registers.
    #pragma unroll 1
    for (int j = 0; j < batch; j++) {
        fe_mul(Wsave[j], P->Y, prefix);
        fe_copy(Zsave[j], P->Z);
        fe_mul(prefix, prefix, P->Z);
        ge_p1p1 t;
        ge_madd(&t, P, &c_step);
        ge_p1p1_to_p3(P, &t);
    }

    fe inv;
    fe_invert(inv, prefix);

    #pragma unroll 1
    for (int k = batch - 1; k >= 0; k--) {
        fe y;
        fe_mul(y, Wsave[k], inv);
        sink(k, y);
        fe_mul(inv, inv, Zsave[k]);
    }
}

// -------------------------------------------------------------------------
// Candidate handling (cold path)
//
// Re-derives the key from the final scalar with full double-and-add -- a
// different code path from the incremental chain -- and refuses to report
// anything if the two disagree.  That catches a chain bug or a transient
// hardware fault before a key is ever written.
// -------------------------------------------------------------------------
__device__ __noinline__ void handle_candidate(
        const uint8_t sc[32], const uint8_t noncebase[32], uint32_t idx,
        const fe y, int plen, Result *results, Shared *sh)
{
    uint8_t fsc[32];
    scalar_add_small(fsc, sc, 8u * idx);
    if (!scalar_is_clamped(fsc)) return;

    ge_p3 R;
    ge_scalarmult_base(&R, fsc);
    uint8_t pub[32];
    ge_p3_tobytes(pub, &R);

    uint8_t ybytes[32];
    fe_tobytes(ybytes, y);
    bool ok = ((pub[31] & 0x7f) == ybytes[31]);
    for (int i = 0; i < 31; i++) if (pub[i] != ybytes[i]) ok = false;
    if (!ok) { atomicExch(&sh->fault, 1u); return; }

    uint8_t ck[32];
    sha3_256_onion_checksum(pub, ck);
    uint8_t raw[35];
    for (int i = 0; i < 32; i++) raw[i] = pub[i];
    raw[32] = ck[0]; raw[33] = ck[1]; raw[34] = 0x03;
    char addr[57];
    base32_encode(raw, addr);
    if (!prefix_matches(addr, c_prefix, plen)) return;

    atomicAdd(&sh->hits, 1u);
    unsigned int slot = atomicAdd(&sh->stored, 1u);
    if (slot >= MAX_SLOTS) return;

    // A distinct signing nonce per key: all keys walked by one thread share a
    // seed, and reusing one nonce across different keys is needless coupling.
    uint8_t nb[32], nh[64];
    for (int i = 0; i < 32; i++) nb[i] = noncebase[i];
    nb[0] ^= (uint8_t)(idx);
    nb[1] ^= (uint8_t)(idx >> 8);
    nb[2] ^= (uint8_t)(idx >> 16);
    nb[3] ^= (uint8_t)(idx >> 24);
    sha512_32(nb, nh);

    Result *r = &results[slot];
    for (int i = 0; i < 32; i++) r->pubkey[i] = pub[i];
    for (int i = 0; i < 32; i++) r->scalar[i] = fsc[i];
    for (int i = 0; i < 32; i++) r->nonce[i]  = nh[i];
    for (int i = 0; i < 57; i++) r->address[i] = addr[i];
}

// -------------------------------------------------------------------------
// Search kernel
// -------------------------------------------------------------------------
__launch_bounds__(THREADS_PER_BLOCK, MIN_BLOCKS_PER_SM)
__global__ void vanity_kernel(int plen, uint64_t target, uint64_t mask,
                              unsigned long long launch_idx,
                              Result * __restrict__ results,
                              Shared * __restrict__ sh,
                              unsigned int stop_at,
                              unsigned long long * __restrict__ counter)
{
    const int gtid = blockIdx.x * blockDim.x + threadIdx.x;

    // Per-thread seed = SHA-512(root XOR thread id XOR launch index).  The
    // root is 32 fresh CSPRNG bytes per launch; gtid and launch index sit at
    // disjoint byte offsets so no two threads can derive the same seed.
    uint8_t buf[32];
    for (int i = 0; i < 32; i++) buf[i] = c_root[i];
    buf[0] ^= (uint8_t)(gtid);
    buf[1] ^= (uint8_t)(gtid >> 8);
    buf[2] ^= (uint8_t)(gtid >> 16);
    buf[3] ^= (uint8_t)(gtid >> 24);
    for (int i = 0; i < 8; i++) buf[4 + i] ^= (uint8_t)(launch_idx >> (8*i));

    uint8_t seed[64];
    sha512_32(buf, seed);
    uint8_t h64[64];
    sha512_32(seed, h64);      // seed[0..31] -> expanded key
    uint8_t sc[32];
    clamp_scalar(sc, h64);

    ge_p3 P;
    ge_scalarmult_base(&P, sc);

    fe Wsave[BINV_N], Zsave[BINV_N];
    unsigned long long local_count = 0;

    for (int base = 0; base < INNER_BATCH; base += BINV_N) {
        // Volatile: another block may have finished the job.  A plain load
        // here would let the compiler hoist it out of the loop.
        if (*(volatile unsigned int *)&sh->stored >= stop_at) break;

        const int batch = (base + BINV_N <= INNER_BATCH) ? BINV_N : (INNER_BATCH - base);

        run_batch(&P, Wsave, Zsave, batch,
            [&] (int k, const fe y) {
                if ((fe_low8_be(y) & mask) == target)
                    handle_candidate(sc, h64 + 32, (uint32_t)(base + k), y,
                                     plen, results, sh);
            });

        local_count += batch;
    }

    atomicAdd(counter, local_count);
}

// -------------------------------------------------------------------------
// Self-tests
// -------------------------------------------------------------------------
__global__ void selftest_kernel(uint8_t *out_pubkey, uint8_t *out_sha512, uint8_t *out_bp) {
    if (threadIdx.x || blockIdx.x) return;

    uint8_t s1[32] = {0};
    s1[0] = 1;
    ge_p3 R;
    ge_scalarmult_base(&R, s1);
    ge_p3_tobytes(out_bp, &R);

    uint8_t seed[32] = {
        0x9d,0x61,0xb1,0x9d,0xef,0xfd,0x5a,0x60,
        0xba,0x84,0x4a,0xf4,0x92,0xec,0x2c,0xc4,
        0x44,0x49,0xc5,0x69,0x7b,0x32,0x69,0x19,
        0x70,0x3b,0xac,0x03,0x1c,0xae,0x7f,0x60
    };
    uint8_t h64[64];
    sha512_32(seed, h64);
    for (int i = 0; i < 64; i++) out_sha512[i] = h64[i];
    uint8_t scalar[32];
    clamp_scalar(scalar, h64);
    ge_p3 Q;
    ge_scalarmult_base(&Q, scalar);
    ge_p3_tobytes(out_pubkey, &Q);
}

// Differential test, producer: run the real batch machinery for one scalar and
// emit every affine y, plus a check that fe_low8_be agrees with fe_tobytes.
//
// Two batches, because the search chains many of them and the point has to
// carry correctly from one to the next.
#define CHAINTEST_BATCHES 2
__global__ void chaintest_produce_kernel(const uint8_t *sc, uint8_t *out_y, unsigned int *bad) {
    if (threadIdx.x || blockIdx.x) return;

    uint8_t s[32];
    for (int i = 0; i < 32; i++) s[i] = sc[i];

    ge_p3 P;
    ge_scalarmult_base(&P, s);

    fe Wsave[BINV_N], Zsave[BINV_N];
    for (int b = 0; b < CHAINTEST_BATCHES; b++) {
        const int off = b * BINV_N;
        run_batch(&P, Wsave, Zsave, BINV_N,
            [&] (int k, const fe y) {
                uint8_t bb[32];
                fe_tobytes(bb, y);
                for (int i = 0; i < 32; i++) out_y[(off + k)*32 + i] = bb[i];

                uint64_t v = 0;
                for (int i = 0; i < 8; i++) v = (v << 8) | bb[i];
                if (v != fe_low8_be(y)) atomicExch(bad, 2u);
            });
    }
}

// Differential test, verifier: thread i recomputes scalar+8i the slow way.
__global__ void chaintest_verify_kernel(const uint8_t *sc, const uint8_t *chain_y,
                                        unsigned int *bad) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= CHAINTEST_BATCHES * BINV_N) return;

    uint8_t s[32], fsc[32];
    for (int k = 0; k < 32; k++) s[k] = sc[k];
    scalar_add_small(fsc, s, 8u * (uint32_t)i);

    ge_p3 R;
    ge_scalarmult_base(&R, fsc);
    uint8_t pub[32];
    ge_p3_tobytes(pub, &R);

    // The chain yields y only; the x-sign bit is not part of it.
    for (int k = 0; k < 31; k++)
        if (pub[k] != chain_y[i*32 + k]) atomicExch(bad, 1u);
    if ((pub[31] & 0x7f) != chain_y[i*32 + 31]) atomicExch(bad, 1u);
}

// -------------------------------------------------------------------------
// Host-side base32 / SHA3-256, used to re-derive the address from the public
// key independently of the GPU before anything is written to disk.
// -------------------------------------------------------------------------
static const uint64_t H_RC[24] = {
    0x0000000000000001ULL,0x0000000000008082ULL,0x800000000000808aULL,0x8000000080008000ULL,
    0x000000000000808bULL,0x0000000080000001ULL,0x8000000080008081ULL,0x8000000000008009ULL,
    0x000000000000008aULL,0x0000000000000088ULL,0x0000000080008009ULL,0x000000008000000aULL,
    0x000000008000808bULL,0x800000000000008bULL,0x8000000000008089ULL,0x8000000000008003ULL,
    0x8000000000008002ULL,0x8000000000000080ULL,0x000000000000800aULL,0x800000008000000aULL,
    0x8000000080008081ULL,0x8000000000008080ULL,0x0000000080000001ULL,0x8000000080008008ULL
};
static const int H_RHO[24] = {1,3,6,10,15,21,28,36,45,55,2,14,27,41,56,8,25,43,62,18,39,61,20,44};
static const int H_PI[24]  = {10,7,11,17,18,3,5,16,8,21,24,4,15,23,19,13,12,2,20,14,22,9,6,1};

static uint64_t h_rotl(uint64_t x, int n) { return (x << n) | (x >> (64 - n)); }

static void host_keccak_f(uint64_t A[25]) {
    for (int round = 0; round < 24; round++) {
        uint64_t C[5], D[5], B[25];
        for (int x = 0; x < 5; x++) C[x] = A[x]^A[x+5]^A[x+10]^A[x+15]^A[x+20];
        for (int x = 0; x < 5; x++) {
            D[x] = C[(x+4)%5] ^ h_rotl(C[(x+1)%5], 1);
            for (int y = 0; y < 5; y++) A[x+5*y] ^= D[x];
        }
        uint64_t last = A[1];
        for (int i = 0; i < 24; i++) {
            int j = H_PI[i];
            B[0] = A[j];
            A[j] = h_rotl(last, H_RHO[i]);
            last = B[0];
        }
        for (int y = 0; y < 5; y++) {
            for (int x = 0; x < 5; x++) B[x] = A[x+5*y];
            for (int x = 0; x < 5; x++) A[x+5*y] = B[x] ^ ((~B[(x+1)%5]) & B[(x+2)%5]);
        }
        A[0] ^= H_RC[round];
    }
}

static void host_onion_checksum(const uint8_t pubkey[32], uint8_t out[32]) {
    uint64_t A[25] = {0};
    uint8_t block[136] = {0};
    const char *p = ".onion checksum";
    for (int i = 0; i < 15; i++) block[i] = (uint8_t)p[i];
    for (int i = 0; i < 32; i++) block[15+i] = pubkey[i];
    block[47]  = 0x03;
    block[48]  = 0x06;
    block[135] = 0x80;
    for (int i = 0; i < 17; i++) {
        uint64_t lane = 0;
        for (int b = 0; b < 8; b++) lane |= ((uint64_t)block[i*8+b]) << (8*b);
        A[i] ^= lane;
    }
    host_keccak_f(A);
    for (int i = 0; i < 4; i++)
        for (int b = 0; b < 8; b++) out[i*8+b] = (uint8_t)((A[i] >> (8*b)) & 0xff);
}

static void host_base32(const uint8_t in[35], char out[57]) {
    for (int i = 0; i < 56; i++) {
        int bit_start = i * 5, byte_idx = bit_start / 8, bit_off = bit_start % 8;
        uint32_t val;
        if (bit_off <= 3) val = (in[byte_idx] >> (3 - bit_off)) & 0x1f;
        else val = ((in[byte_idx] << (bit_off - 3)) | (in[byte_idx+1] >> (11 - bit_off))) & 0x1f;
        out[i] = (val < 26) ? (char)('a' + val) : (char)('2' + (val - 26));
    }
    out[56] = '\0';
}

static void host_address(const uint8_t pubkey[32], char out[57]) {
    uint8_t ck[32], raw[35];
    host_onion_checksum(pubkey, ck);
    memcpy(raw, pubkey, 32);
    raw[32] = ck[0]; raw[33] = ck[1]; raw[34] = 0x03;
    host_base32(raw, out);
}

// -------------------------------------------------------------------------
// Entropy and secret handling
// -------------------------------------------------------------------------
static void get_entropy(void *buf, size_t len) {
    uint8_t *p = (uint8_t *)buf;
    size_t got = 0;
    while (got < len) {
        ssize_t n = getrandom(p + got, len - got, 0);
        if (n < 0) {
            if (errno == EINTR) continue;
            int fd = open("/dev/urandom", O_RDONLY);
            if (fd < 0) { perror("/dev/urandom"); exit(1); }
            while (got < len) {
                n = read(fd, p + got, len - got);
                if (n <= 0) {
                    if (n < 0 && errno == EINTR) continue;
                    fprintf(stderr, "Failed to read entropy from /dev/urandom\n");
                    exit(1);
                }
                got += (size_t)n;
            }
            close(fd);
            return;
        }
        got += (size_t)n;
    }
}

static void secure_zero(void *p, size_t n) {
    volatile uint8_t *v = (volatile uint8_t *)p;
    while (n--) *v++ = 0;
}

// -------------------------------------------------------------------------
// Key files
// -------------------------------------------------------------------------
static int write_file(const char *path, const void *buf, size_t len, mode_t mode) {
    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL, mode);
    if (fd < 0) {
        fprintf(stderr, "Cannot create %s: %s\n", path, strerror(errno));
        return -1;
    }
    if (fchmod(fd, mode) != 0)
        fprintf(stderr, "Warning: cannot set mode on %s: %s\n", path, strerror(errno));

    const uint8_t *p = (const uint8_t *)buf;
    size_t off = 0;
    while (off < len) {
        ssize_t n = write(fd, p + off, len - off);
        if (n <= 0) {
            if (n < 0 && errno == EINTR) continue;
            fprintf(stderr, "Write failed on %s: %s\n", path, strerror(errno));
            close(fd);
            return -1;
        }
        off += (size_t)n;
    }
    if (fsync(fd) != 0) {
        fprintf(stderr, "fsync failed on %s: %s\n", path, strerror(errno));
        close(fd);
        return -1;
    }
    if (close(fd) != 0) {
        fprintf(stderr, "close failed on %s: %s\n", path, strerror(errno));
        return -1;
    }
    return 0;
}

// Returns 0 on success.  Refuses to write anything unless the address
// re-derived on the host from the public key matches what the GPU reported.
static int write_key_files(const char *outdir, const Result *r) {
    char check[57];
    host_address(r->pubkey, check);
    if (memcmp(check, r->address, 56) != 0) {
        fprintf(stderr, "\nREFUSING to write: host re-derived a different address\n"
                        "  GPU:  %.56s\n  host: %.56s\n", r->address, check);
        return -1;
    }
    if (!(r->scalar[0] % 8 == 0 && (r->scalar[31] & 0xc0) == 0x40)) {
        fprintf(stderr, "\nREFUSING to write %.56s: scalar is not clamped\n", r->address);
        return -1;
    }

    char pubp[1024], secp[1024], hostp[1024];
    if (snprintf(pubp,  sizeof(pubp),  "%s/%.56s_hs_ed25519_public_key", outdir, r->address) >= (int)sizeof(pubp) ||
        snprintf(secp,  sizeof(secp),  "%s/%.56s_hs_ed25519_secret_key", outdir, r->address) >= (int)sizeof(secp) ||
        snprintf(hostp, sizeof(hostp), "%s/%.56s_hostname",              outdir, r->address) >= (int)sizeof(hostp)) {
        fprintf(stderr, "Output path too long\n");
        return -1;
    }

    uint8_t pub[64], sec[96];
    memcpy(pub, "== ed25519v1-public: type0 ==\0\0\0", 32);
    memcpy(pub + 32, r->pubkey, 32);
    memcpy(sec, "== ed25519v1-secret: type0 ==\0\0\0", 32);
    memcpy(sec + 32, r->scalar, 32);
    memcpy(sec + 64, r->nonce, 32);

    char hostname[64];
    int hn = snprintf(hostname, sizeof(hostname), "%.56s.onion\n", r->address);
    if (hn < 0 || hn >= (int)sizeof(hostname)) {
        fprintf(stderr, "Internal error formatting hostname\n");
        return -1;
    }

    int rc = 0;
    if (write_file(secp, sec, sizeof(sec), 0600) != 0) rc = -1;
    if (rc == 0 && write_file(pubp, pub, sizeof(pub), 0644) != 0) rc = -1;
    if (rc == 0 && write_file(hostp, hostname, (size_t)hn, 0644) != 0) rc = -1;

    secure_zero(sec, sizeof(sec));

    if (rc != 0) {
        // Never leave a half-written key set: an address whose secret is
        // missing is useless, and one whose public file is missing is
        // confusing.  Remove whatever this key managed to create.
        unlink(secp); unlink(pubp); unlink(hostp);
    }

    if (rc == 0) {
        int dfd = open(outdir, O_RDONLY | O_DIRECTORY);
        if (dfd >= 0) { fsync(dfd); close(dfd); }
        printf("    %s\n    %s\n    %s\n", secp, pubp, hostp);
    }
    return rc;
}

// -------------------------------------------------------------------------
static void usage(const char *prog) {
    fprintf(stderr,
        "Usage: %s [options] <prefix>\n"
        "  -n <count>   stop after finding <count> addresses (default 1)\n"
        "  -o <dir>     output directory for key files (default \".\")\n"
        "  --bench      run one kernel launch and report throughput and hit rate\n"
        "  prefix       desired address prefix, base32 only: a-z and 2-7\n"
        "\nExample: %s -n 2 -o /var/lib/tor/keys mysite\n", prog, prog);
}

static const char *human_time(double s, char *buf, size_t n) {
    if (s < 1.0)        snprintf(buf, n, "%.0f ms", s * 1000.0);
    else if (s < 90.0)  snprintf(buf, n, "%.1f s", s);
    else if (s < 5400)  snprintf(buf, n, "%.1f min", s / 60.0);
    else if (s < 172800) snprintf(buf, n, "%.1f h", s / 3600.0);
    else if (s < 3.15e9) snprintf(buf, n, "%.1f days", s / 86400.0);
    else                snprintf(buf, n, "%.2g years", s / 3.156e7);
    return buf;
}

int main(int argc, char **argv) {
    long want = 1;
    const char *outdir = ".";
    const char *pattern = NULL;
    int bench = 0;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-n") && i+1 < argc) {
            char *end = NULL;
            want = strtol(argv[++i], &end, 10);
            if (!end || *end || want < 1 || want > 1000000) {
                fprintf(stderr, "-n must be between 1 and 1000000\n");
                return 1;
            }
        } else if (!strcmp(argv[i], "-o") && i+1 < argc) {
            outdir = argv[++i];
        } else if (!strcmp(argv[i], "--bench")) {
            bench = 1;
        } else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) {
            usage(argv[0]);
            return 0;
        } else if (argv[i][0] != '-' && !pattern) {
            pattern = argv[i];
        } else {
            usage(argv[0]);
            return 1;
        }
    }
    if (!pattern) { usage(argv[0]); return 1; }

    int plen = (int)strlen(pattern);
    if (plen < 1 || plen > 56) {
        fprintf(stderr, "Prefix must be 1..56 characters\n");
        return 1;
    }

    // Lower-case and validate; build the fast-path target and mask.
    char prefix[64] = {0};
    uint64_t target = 0, mask = 0;
    for (int i = 0; i < plen; i++) {
        char c = pattern[i];
        if (c >= 'A' && c <= 'Z') c += 32;
        uint32_t val;
        if (c >= 'a' && c <= 'z')      val = (uint32_t)(c - 'a');
        else if (c >= '2' && c <= '7') val = (uint32_t)(c - '2') + 26;
        else {
            fprintf(stderr, "Invalid base32 character '%c' in prefix "
                            "(allowed: a-z, 2-7)\n", pattern[i]);
            return 1;
        }
        prefix[i] = c;
        if (i < FAST_CHARS) {
            int shift = 59 - 5*i;             // character i occupies stream bits [5i, 5i+5)
            target |= (uint64_t)val << shift;
            mask   |= (uint64_t)0x1f  << shift;
        }
    }

    const double expected = pow(32.0, (double)plen);
    char tb[64];
    printf("Prefix: %s   expected attempts: %.3g\n", prefix, expected);

    if (mkdir(outdir, 0700) != 0 && errno != EEXIST) {
        fprintf(stderr, "Cannot create output directory %s: %s\n", outdir, strerror(errno));
        return 1;
    }
    if (access(outdir, W_OK | X_OK) != 0) {
        fprintf(stderr, "Output directory %s is not writable: %s\n", outdir, strerror(errno));
        return 1;
    }
    {
        struct stat st;
        if (!bench && stat(outdir, &st) == 0 && (st.st_mode & 0077))
            printf("Warning: %s is accessible to other users (mode %o); Tor refuses\n"
                   "         a HiddenServiceDir with group or other permissions.\n",
                   outdir, (unsigned)(st.st_mode & 07777));
    }

    signal(SIGINT, handle_sigint);
    signal(SIGTERM, handle_sigint);

    // ---- self-test: Ed25519 against known answers
    {
        uint8_t *d_pub, *d_sha, *d_bp;
        CUDA_CHECK(cudaMalloc(&d_pub, 32));
        CUDA_CHECK(cudaMalloc(&d_sha, 64));
        CUDA_CHECK(cudaMalloc(&d_bp, 32));
        selftest_kernel<<<1,1>>>(d_pub, d_sha, d_bp);
        CUDA_CHECK(cudaDeviceSynchronize());
        uint8_t h_pub[32], h_bp[32];
        CUDA_CHECK(cudaMemcpy(h_pub, d_pub, 32, cudaMemcpyDeviceToHost));
        CUDA_CHECK(cudaMemcpy(h_bp,  d_bp,  32, cudaMemcpyDeviceToHost));
        CUDA_CHECK(cudaFree(d_pub)); CUDA_CHECK(cudaFree(d_sha)); CUDA_CHECK(cudaFree(d_bp));

        const uint8_t want_bp[32] = {
            0x58,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,
            0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66 };
        const uint8_t want_pub[32] = {
            0xd7,0x5a,0x98,0x01,0x82,0xb1,0x0a,0xb7,0xd5,0x4b,0xfe,0xd3,0xc9,0x64,0x07,0x3a,
            0x0e,0xe1,0x72,0xf3,0xda,0xa6,0x23,0x25,0xaf,0x02,0x1a,0x68,0xf7,0x07,0x51,0x1a };
        if (memcmp(h_bp, want_bp, 32) || memcmp(h_pub, want_pub, 32)) {
            fprintf(stderr, "Self-test FAILED (base point / RFC 8032 vector 1).\n");
            return 1;
        }
        printf("Self-test: base point OK, RFC 8032 vector 1 OK\n");
    }

    // ---- cached step point
    init_step_kernel<<<1,1>>>();
    CUDA_CHECK(cudaDeviceSynchronize());
    {
        ge_cached step;
        CUDA_CHECK(cudaMemcpyFromSymbol(&step, d_step_out, sizeof(step)));
        CUDA_CHECK(cudaMemcpyToSymbol(c_step, &step, sizeof(step)));
    }
    CUDA_CHECK(cudaMemcpyToSymbol(c_prefix, prefix, sizeof(prefix)));

    // ---- differential self-test: the incremental chain and batch inversion
    // for a whole batch, against full scalar multiplication of scalar+8i.
    {
        uint8_t seed[32];
        get_entropy(seed, sizeof(seed));   // a random scalar every run
        uint8_t *d_sc, *d_y;
        unsigned int *d_bad, h_bad = 0;
        CUDA_CHECK(cudaMalloc(&d_sc, 32));
        CUDA_CHECK(cudaMalloc(&d_y, CHAINTEST_BATCHES * BINV_N * 32));
        CUDA_CHECK(cudaMalloc(&d_bad, sizeof(unsigned int)));
        CUDA_CHECK(cudaMemcpy(d_bad, &h_bad, sizeof(h_bad), cudaMemcpyHostToDevice));
        seed[0]  &= 248;      // a clamped scalar, as the search uses
        seed[31] &= 127;
        seed[31] |= 64;
        CUDA_CHECK(cudaMemcpy(d_sc, seed, 32, cudaMemcpyHostToDevice));

        chaintest_produce_kernel<<<1,1>>>(d_sc, d_y, d_bad);
        chaintest_verify_kernel<<<(CHAINTEST_BATCHES*BINV_N+127)/128, 128>>>(d_sc, d_y, d_bad);
        CUDA_CHECK(cudaDeviceSynchronize());
        CUDA_CHECK(cudaMemcpy(&h_bad, d_bad, sizeof(h_bad), cudaMemcpyDeviceToHost));
        CUDA_CHECK(cudaFree(d_sc)); CUDA_CHECK(cudaFree(d_y)); CUDA_CHECK(cudaFree(d_bad));
        secure_zero(seed, sizeof(seed));

        if (h_bad == 1) {
            fprintf(stderr, "Self-test FAILED: incremental chain disagrees with "
                            "scalar multiplication.\n");
            return 1;
        }
        if (h_bad == 2) {
            fprintf(stderr, "Self-test FAILED: fe_low8_be disagrees with fe_tobytes.\n");
            return 1;
        }
        printf("Self-test: incremental chain matches scalar multiplication "
               "over %d consecutive keys\n", CHAINTEST_BATCHES * BINV_N);
    }

    Result *d_results = NULL, *h_results = NULL;
    Shared *d_shared = NULL;
    unsigned long long *d_counter = NULL;
    CUDA_CHECK(cudaMalloc(&d_results, sizeof(Result) * MAX_SLOTS));
    CUDA_CHECK(cudaMalloc(&d_shared, sizeof(Shared)));
    CUDA_CHECK(cudaMalloc(&d_counter, sizeof(unsigned long long)));
    h_results = (Result *)calloc(MAX_SLOTS, sizeof(Result));
    if (!h_results) { fprintf(stderr, "out of memory\n"); return 1; }
    // Best-effort: keep the window where secret scalars sit in host memory out
    // of swap.  Not fatal if the rlimit forbids it.
    (void)mlock(h_results, sizeof(Result) * MAX_SLOTS);

    unsigned long long zero64 = 0;
    CUDA_CHECK(cudaMemcpy(d_counter, &zero64, sizeof(zero64), cudaMemcpyHostToDevice));

    printf("Launch: %d blocks x %d threads, %d keys/thread = %llu keys/launch\n\n",
           BLOCKS, THREADS_PER_BLOCK, INNER_BATCH,
           (unsigned long long)TOTAL_THREADS * INNER_BATCH);

    long found_total = 0;
    unsigned long long total_keys = 0, hits_total = 0;
    unsigned long long launch_idx = 0;
    struct timespec t0;
    clock_gettime(CLOCK_MONOTONIC, &t0);

    while (!g_stop && (bench ? (launch_idx < 1) : (found_total < want))) {
        unsigned int stop_at = bench ? 0xffffffffu
                                     : (unsigned int)((want - found_total < MAX_SLOTS)
                                                      ? (want - found_total) : MAX_SLOTS);

        // Fresh CSPRNG root for every launch: the secret keys this program can
        // emit are only as unpredictable as this value.
        uint8_t root[32];
        get_entropy(root, sizeof(root));
        CUDA_CHECK(cudaMemcpyToSymbol(c_root, root, sizeof(root)));
        secure_zero(root, sizeof(root));

        Shared sh = {0, 0, 0};
        CUDA_CHECK(cudaMemcpy(d_shared, &sh, sizeof(sh), cudaMemcpyHostToDevice));

        struct timespec l0, l1;
        clock_gettime(CLOCK_MONOTONIC, &l0);
        vanity_kernel<<<BLOCKS, THREADS_PER_BLOCK>>>(
            plen, target, mask, launch_idx, d_results, d_shared, stop_at, d_counter);
        CUDA_CHECK(cudaDeviceSynchronize());
        clock_gettime(CLOCK_MONOTONIC, &l1);

        CUDA_CHECK(cudaMemcpy(&sh, d_shared, sizeof(sh), cudaMemcpyDeviceToHost));
        CUDA_CHECK(cudaMemcpy(&total_keys, d_counter, sizeof(total_keys), cudaMemcpyDeviceToHost));
        hits_total += sh.hits;

        if (sh.fault) {
            fprintf(stderr, "\nFATAL: a key derived by the incremental chain did not match\n"
                            "full scalar multiplication of the same scalar.  This is a GPU\n"
                            "fault (overclock/thermal) or a bug -- nothing has been written.\n");
            return 2;
        }

        unsigned int n = sh.stored < MAX_SLOTS ? sh.stored : MAX_SLOTS;
        if (n && !bench) {
            CUDA_CHECK(cudaMemcpy(h_results, d_results, sizeof(Result) * n, cudaMemcpyDeviceToHost));
            for (unsigned int i = 0; i < n && found_total < want; i++) {
                printf("\n[+] %.56s.onion\n", h_results[i].address);
                if (write_key_files(outdir, &h_results[i]) == 0) found_total++;
                else { fprintf(stderr, "Giving up: key files could not be written.\n"); return 3; }
            }
            secure_zero(h_results, sizeof(Result) * n);
            CUDA_CHECK(cudaMemset(d_results, 0, sizeof(Result) * n));
        }

        double lelapsed = (l1.tv_sec - l0.tv_sec) + (l1.tv_nsec - l0.tv_nsec)*1e-9;
        double elapsed  = (l1.tv_sec - t0.tv_sec) + (l1.tv_nsec - t0.tv_nsec)*1e-9;
        double rate     = elapsed > 0 ? total_keys / elapsed : 0;

        if (bench) {
            double keys = (double)total_keys;
            printf("Keys:      %llu in %.3f s\n", total_keys, lelapsed);
            printf("Rate:      %.1f M keys/s\n", keys / lelapsed / 1e6);
            printf("Hits:      %u  (expected %.1f for a %d-character prefix)\n",
                   sh.hits, keys / expected, plen);
        } else {
            printf("\rKeys: %llu  rate: %.1f M/s  elapsed: %.1fs  ETA: %s        ",
                   total_keys, rate / 1e6, elapsed,
                   human_time(rate > 0 ? expected / rate : 0, tb, sizeof(tb)));
            fflush(stdout);
        }
        launch_idx++;
    }

    if (!bench) {
        printf("\n\nFound %ld address(es); %llu keys tried, %llu total matches.\n",
               found_total, total_keys, hits_total);
        if (found_total)
            printf("Verify independently with:  python3 verify.py %s\n", outdir);
    }

    secure_zero(h_results, sizeof(Result) * MAX_SLOTS);
    munlock(h_results, sizeof(Result) * MAX_SLOTS);
    free(h_results);
    CUDA_CHECK(cudaMemset(d_results, 0, sizeof(Result) * MAX_SLOTS));
    CUDA_CHECK(cudaFree(d_results));
    CUDA_CHECK(cudaFree(d_shared));
    CUDA_CHECK(cudaFree(d_counter));
    return 0;
}
