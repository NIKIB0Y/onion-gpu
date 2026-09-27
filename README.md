# onion-gpu

[![build](https://github.com/NIKIB0Y/onion-gpu/actions/workflows/build.yml/badge.svg)](https://github.com/NIKIB0Y/onion-gpu/actions/workflows/build.yml)

GPU-accelerated Tor v3 vanity `.onion` address generator using CUDA.

Generates Ed25519 key pairs on the GPU, computes the v3 onion address for each, and
stops when it finds addresses starting with a chosen prefix.

Measured on an RTX 5060 (Blackwell GB206, sm_120): **917 M keys/s** sustained —
about 16× mkp224o on a Ryzen 7 5700X, [measured on the same
machine](#comparison-with-mkp224o).

Needs an NVIDIA GPU, the CUDA toolkit, and Linux.

## Download

Pre-built binaries are on the [releases
page](https://github.com/NIKIB0Y/onion-gpu/releases). They statically link the CUDA
runtime, so **you only need an NVIDIA driver — not the CUDA toolkit**. The Linux
binary links nothing outside glibc itself (`libc`, `libm`, `libpthread`, `librt`,
`libdl`) and needs glibc 2.29 or newer; the Windows build links the CRT statically.
Both carry GPU code for `sm_50, 60, 70, 80, 90, 100, 120` — every major architecture
from Maxwell (GTX 900) through Blackwell (RTX 50xx) — plus PTX so future cards work
by JIT.

| File | For |
|------|-----|
| `onion-gpu-linux-x86_64.tar.gz` | any x86-64 Linux with glibc 2.29+ (Ubuntu 20.04+, Debian 11+, RHEL 9+) |
| `onion-gpu-windows-x86_64.zip` | Windows 10/11 x64 |

```bash
tar xzf onion-gpu-linux-x86_64.tar.gz && cd onion-gpu-linux-x86_64
./onion-gpu -n 1 -o keys vanity
```

On Windows, unzip and run `onion-gpu.exe -n 1 -o keys vanity`.

The Linux binary is executed on an RTX 5060 before release: self-tests pass and a
generated key is checked with `verify.py`.

The Windows binary is **never executed before release** — no CI runner has an NVIDIA
GPU. What is checked is that it compiles, that it is a valid PE32+ console
executable, that its embedded device-code section is present and complete, and that
it really does import `BCryptGenRandom` and `VirtualLock`. Its actual runtime
behaviour on Windows is untested; please report anything that misbehaves.

## Quick start (from source)

```bash
make                                  # targets your GPU automatically
./onion-gpu -n 1 -o keys vanity       # 6 characters: about a second
python3 verify.py keys                # independent check of what was written
```

## Usage

```
./onion-gpu [options] <prefix>

  -n <count>   stop after finding <count> addresses (default: 1)
  -o <dir>     output directory for key files (default: current directory)
  --bench      run one kernel launch and report throughput and hit rate
  prefix       desired prefix, base32 characters only: a-z and 2-7 (case-insensitive)

Examples:
  ./onion-gpu vani
  ./onion-gpu -n 5 -o /var/lib/tor/keys mysite
```

Three files are written per address, named after it:

| File | Mode | Contents |
|------|------|----------|
| `<addr>_hs_ed25519_secret_key` | 0600 | Tor `hs_ed25519_secret_key` (32-byte header + clamped scalar + nonce) |
| `<addr>_hs_ed25519_public_key` | 0644 | Tor `hs_ed25519_public_key` (32-byte header + 32-byte pubkey) |
| `<addr>_hostname` | 0644 | the full `.onion` hostname |

### Deploying one

Tor wants these three files under fixed names in the `HiddenServiceDir`:

```bash
install -d -m 700 /var/lib/tor/myservice
cp <addr>_hs_ed25519_secret_key /var/lib/tor/myservice/hs_ed25519_secret_key
cp <addr>_hs_ed25519_public_key /var/lib/tor/myservice/hs_ed25519_public_key
cp <addr>_hostname              /var/lib/tor/myservice/hostname
chown -R tor:tor /var/lib/tor/myservice
chmod 600 /var/lib/tor/myservice/*
```

Tor refuses a `HiddenServiceDir` with group or other permissions, so the directory
must be `700` and owned by the user Tor runs as.

### Verifying a key independently

```bash
python3 verify.py <dir>
```

`verify.py` re-derives everything on the CPU in pure Python — no code shared with
the CUDA implementation — and checks that the secret scalar really does produce the
published address, that the scalar is clamped, and that the secret key file is not
readable by other users.

## Building

Requires an NVIDIA GPU and the CUDA toolkit (12.8 or newer for `sm_120`; older
toolkits are fine for older architectures). No other dependencies — `verify.py`
uses only the Python standard library.

```bash
make
```

That targets the GPU in your machine automatically (`-arch=native`). To choose
explicitly, or to build on a machine with no GPU:

```bash
make ARCH=sm_89       # one architecture: sm_75 Turing, sm_86 RTX 30xx,
                      # sm_89 RTX 40xx, sm_90 H100, sm_120 RTX 50xx
make ARCH=all-major   # every architecture the toolkit knows (larger binary)
```

On distributions where `nvcc` is not on `PATH`, add `NVCC=/opt/cuda/bin/nvcc`.

### Windows

There is no makefile for Windows; build directly with `nvcc` from a Developer
Command Prompt (Visual Studio C++ tools are required by `nvcc` itself):

```
nvcc -arch=native -cudart static -Xcompiler "/O2 /MT" -I. -o onion-gpu.exe main.cu
```

Host optimisation comes from `/O2` (the MSVC spelling of `-O3`) and device code is
optimised by default, so no `-O` flag is needed.

Note that CUDA is picky about the Visual Studio version: CUDA 12.9 rejects Visual
Studio 18 with *"unsupported Microsoft Visual Studio version"*. Either use a CUDA
release that lists your VS version as supported, or pass
`-allow-unsupported-compiler` at your own risk.

Use `-arch=all-major` in place of `-arch=native` to build a binary that runs on any
GPU rather than only the one in the build machine.

## Compatibility

Developed and measured on an RTX 5060 (Blackwell, sm_120) with CUDA 13.4 on Linux.
Compilation is verified for sm_75 through sm_120; **execution has only been tested
on that one card**, so treat other GPUs as untested rather than unsupported.

- **Linux and Windows.** Entropy comes from `getrandom(2)` on Linux and
  `BCryptGenRandom` on Windows; memory locking uses `mlock` / `VirtualLock`. macOS
  has no CUDA support at all any more. Note that Windows builds cannot apply POSIX
  `0600` permissions to the secret key file — see [SECURITY.md](SECURITY.md).
- **Any CUDA-capable NVIDIA GPU** in principle — nothing architecture-specific is
  used, and `make` targets whatever card you have. Note that CUDA 13 dropped
  Maxwell, Pascal and Volta (sm_50–sm_70); those need CUDA 12.x. Blackwell
  (sm_120) needs CUDA 12.8 or newer.
- **About 1.5 GB of VRAM** on a 30-SM GPU. Each thread holds two `BINV_N`-entry
  arrays in local memory (~32 KB), and the driver reserves that for every thread
  slot the device can hold — so the requirement scales with SM count, not with the
  launch size. On a card with little memory, build with `-DBINV_N=128` to cut it to
  roughly a third (at some cost in speed). If the allocation fails you get a clear
  CUDA error, not silent corruption.
- **The tuning is specific to this card.** `BINV_N=384`, 3 blocks/SM and 16 896
  keys per thread were picked by measurement on an RTX 5060. On a different GPU,
  re-sweep them with `--bench` — see the knobs listed under Performance.

## Correctness checks

Three self-tests run at every startup, all of them fatal on failure:

1. Scalar 1 maps to the Ed25519 base point.
2. RFC 8032 test vector 1 reproduces the published public key.
3. **Differential test of the search itself.** For a random scalar `s`, the
   incremental chain and batch inversion produce all `BINV_N` affine y-coordinates,
   and a second kernel independently recomputes `s + 8i` for every `i` with full
   double-and-add scalar multiplication. Every value must agree. This is what
   catches a bug in the fast path, which would otherwise show up only as a search
   that silently finds fewer addresses than it should.

Beyond startup, every candidate is re-derived from its final scalar by full
double-and-add and cross-checked against the incremental chain before it is
reported, so a chain bug or a transient GPU fault cannot emit a key that does not
match its address. The host then re-derives the address from the public key with
its own SHA3-256 and base32 and refuses to write anything on a mismatch.

`--bench` also reports the number of matches found in one launch against the
expected count, which is the check that the prefix test is neither too strict nor
too loose.

## Security notes

- **Key material comes from the kernel CSPRNG.** Every launch draws a fresh 32-byte
  root via `getrandom(2)`, and each thread derives its seed as
  `SHA-512(root ⊕ thread id ⊕ launch index)`, with the thread id and launch index at
  disjoint byte offsets so no two threads can collide. The root never leaves memory
  and is zeroed after use.
- **Do not generate long-term keys with a version of this program that seeds from
  the clock.** Until this was fixed, the only entropy was `time(NULL)`: two runs
  started in the same second produced byte-identical keys, and anyone who knew the
  address and roughly when it was made could re-derive the secret key in a feasible
  search. Addresses generated that way should not be used as a service identity.
- Secret key files are `0600` regardless of umask, are created with `O_EXCL` so an
  existing key is never overwritten, and are `fsync`ed before being reported. A
  failed write removes the partial key set instead of leaving one behind.
- Secret scalars in host memory are `mlock`ed where permitted and zeroed as soon as
  they have been written.
- Each emitted key gets its own signing nonce, so keys walked by the same thread
  share nothing but a discarded root.
- Scalars are rejected unless they are already in clamped form. Tor re-clamps on
  load, so a non-clamped scalar would be silently altered and would no longer match
  the published address.
- **Not constant-time.** Scalar multiplication branches on secret bits. That is
  acceptable here — the scalar is random, local, and discarded unless it matches —
  but **do not reuse this code for Ed25519 signing.**

## How it works

Each GPU thread draws one seed, does **one** full scalar multiplication to get a
starting point, and then walks the curve in steps of `8 × BasePoint`. Points are
processed in groups of `BINV_N`; each group needs exactly one field inversion.

Three things make the inner loop cheap:

**A cached affine step.** The step point is precomputed once as `(y−x, y+x, 2d·xy)`
with `Z = 1`, so the mixed addition needs 3 multiplies instead of 5 — with `Z = 1`
the term `D = 2·Z_p·Z_q` becomes a free doubling of `Z_p`. With the 4 multiplies
that convert back to extended coordinates, the step is 7 multiplies, the known
optimum for mixed addition on `a = −1` twisted Edwards (madd-2008-hwcd-3).

**Montgomery's trick fused into the chain.** Rather than storing `Y`, `Z` and the
running products separately, the forward pass stores `W_j = Y_j · prefix_{j−1}`
alongside `Z_j`, where `prefix_j = Z_0·…·Z_j`. The backward pass is then

```
y_k = W_k · inv        (inv = 1/prefix_k on entry)
inv = inv · Z_k        (leaves 1/prefix_{k-1} for the next step)
```

because `W_k / prefix_k = Y_k · prefix_{k−1} / prefix_k = Y_k / Z_k`. That folds the
forward product into values already being stored: **two** local arrays instead of
four, and 160 bytes of local memory traffic per key instead of ~400, at the same
four multiplies per key.

**No base32 in the hot loop.** The address is base32 taken MSB-first over the byte
stream, so address character *i* occupies bit positions `[5i, 5i+5)` of the public
key. Packing the low 8 bytes of the y-coordinate into one big-endian word turns a
prefix test of up to 12 characters into a single masked 64-bit compare — no
encoding, no per-character loop, and no 57-byte buffer per key. Only the x-sign bit
and the checksum need more, and neither affects the first 49 characters, so `x` is
never computed at all until a candidate hits: the sign bit lands at stream position
`31·8 = 248`, inside character 49, and the checksum starts at character 51.

Longer prefixes still work — anything past the 12-character window is checked on the
(rare) candidate path, which recomputes the full public key, checksum and address.

Cost per key, in field multiplies:

| Step | Multiplies |
|------|-----------|
| `ge_madd` (cached affine step) | 3 |
| `ge_p1p1_to_p3` | 4 |
| `W_j` and running product | 2 |
| `y_k` and inverse update | 2 |
| `fe_invert`, amortised over `BINV_N = 384` | 0.7 |
| **total** | **~11.7** |

## Performance

RTX 5060 (Blackwell GB206, sm_120), 512 blocks × 128 threads, `BINV_N = 384`,
16 896 keys per thread per launch:

| Metric | Value |
|--------|-------|
| Sustained | 917 M keys/s |
| Single launch | ~940 M keys/s |

Expected attempts for an *n*-character prefix is 32ⁿ:

| Prefix | Expected time |
|--------|---------------|
| 4 chars | 1 ms |
| 5 chars | 37 ms |
| 6 chars | 1.2 s |
| 7 chars | 38 s |
| 8 chars | 20 min |
| 9 chars | 11 h |
| 10 chars | 14 days |

### How it got here

| Step | Technique | Keys/s |
|------|-----------|--------|
| Baseline | full scalar mult per key | 2.6 M |
| + incremental adds | one `ge_add` per key instead | ~60 M |
| + batch inversion, N=4 | Montgomery's trick | ~157 M |
| + register tuning | `__noinline__` on heavy callees, `unroll 1` on the save loops | ~172 M |
| + N=256 | amortise `fe_invert` further | 617 M |
| + cached affine step, fused prefix product, masked prefix test | the three above, measured together at the old N=256 tuning | ~840 M |
| + retuned: N=384, 3 blocks/SM, 16 896 keys/thread | | **917 M** |

The first five rows are from this project's earlier development. The last two were
measured with `--bench` against that 617 M/s build, which re-measures at 643–647 M/s
once the GPU is warm — the fairer comparison, making the current figure about 1.42×.

The remaining per-key cost is close to the floor for this approach: 7 of the ~11.7
multiplies are the mixed addition itself, which is provably minimal, and the
inversion is already amortised to 0.7. Local memory traffic at 917 M keys/s is
~147 GB/s of the card's ~448 GB/s, so the kernel is instruction-bound rather than
bandwidth-bound.

Tuning knobs can be overridden at compile time without editing the source:
`BINV_N`, `INNER_BATCH`, `BLOCKS`, `THREADS_PER_BLOCK`, `MIN_BLOCKS_PER_SM`,
`FAST_CHARS`. For example `nvcc -DBINV_N=256 ...`.

## Comparison with mkp224o

[mkp224o](https://github.com/cathugger/mkp224o) is the standard CPU vanity
generator. Measured on this machine (commit `5172c0f`, 2024-02-15) against an
AMD Ryzen 7 5700X (8 cores / 16 threads), built `-O3 -march=native` with
`--enable-intfilter --enable-binsearch`:

| ed25519 backend | Keys/s |
|-----------------|--------|
| `amd64-64-24k`  | **56.1 M** |
| `donna` (default) | 50.2 M |
| `amd64-51-30k`  | 45.8 M |
| `donna-sse2`    | 29.1 M |

16 threads beat 8 (55.8 vs 49.8 M/s), 24 gained nothing, and the default
`batchnum` of 2048 was optimal (512 → 54.5, 8192 → 54.6). So mkp224o's best on
this CPU is ~56 M keys/s.

| Implementation | Hardware | Keys/s |
|----------------|----------|--------|
| mkp224o, `amd64-64-24k`, 16 threads | Ryzen 7 5700X | 56 M |
| **onion-gpu** | RTX 5060 | **917 M** |

**~16× faster** on one mid-range consumer GPU.

The two tools report the same unit. mkp224o's `calc/sec` was cross-checked against
its own wall-clock time to find 60 five-character addresses: 55.4 M/s self-reported
vs 55.9 M/s implied by `60 × 32⁵ / t`, agreeing within 1%. (A first attempt with 20
keys came out 60% slow — at n=20 the relative spread of a geometric distribution is
~22%, so that was noise, not a discrepancy.)

Head-to-head on the identical task — 60 addresses with a five-character prefix,
wall clock, including process startup and writing every key file:

| | Time | Implied keys/s |
|--|------|----------------|
| mkp224o | 36.0 s | 56 M |
| onion-gpu | 2.18 s | 925 M |

**16.5× on wall clock.** The 925 M/s implied here, derived purely from time-to-find,
independently confirms the 917 M/s counter-based figure.

The GPU drew 143 W during the search. CPU package power could not be read
(`intel-rapl` energy counters need root on this kernel), so no keys-per-joule
comparison is claimed.

## Cryptographic details

- Curve: **Ed25519** (twisted Edwards, `a = -1`, `d = -121665/121666 mod p`,
  `p = 2²⁵⁵ − 19`)
- Field arithmetic: 10-limb 25.5-bit representation (ref10 style). All limb products
  accumulate in 64-bit, which leaves room for the limb widening the addition formula
  introduces; the bound is worked out in the comment above `ge_madd` and the cached
  step constants are canonicalised so it holds.
- Key derivation: `SHA-512(seed)[0:32]`, clamped per RFC 8032 §5.1.5.
- Onion address: `base32(pubkey ‖ sha3_256(".onion checksum" ‖ pubkey ‖ 0x03)[0:2] ‖ 0x03)`

## License

MIT — see [LICENSE](LICENSE).

## Acknowledgements

- The field arithmetic follows the 10-limb `ref10` representation from Daniel J.
  Bernstein's Ed25519 reference implementation (SUPERCOP, public domain).
- [mkp224o](https://github.com/cathugger/mkp224o) by cathugger is the established
  CPU implementation, and the reference this project is measured against. No code
  is shared with it.
- Security reporting and known limitations: [SECURITY.md](SECURITY.md).
