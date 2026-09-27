#pragma once
#include <stdint.h>

__device__ __constant__ uint64_t KECCAK_RC[24] = {
    0x0000000000000001ULL,0x0000000000008082ULL,0x800000000000808aULL,0x8000000080008000ULL,
    0x000000000000808bULL,0x0000000080000001ULL,0x8000000080008081ULL,0x8000000000008009ULL,
    0x000000000000008aULL,0x0000000000000088ULL,0x0000000080008009ULL,0x000000008000000aULL,
    0x000000008000808bULL,0x800000000000008bULL,0x8000000000008089ULL,0x8000000000008003ULL,
    0x8000000000008002ULL,0x8000000000000080ULL,0x000000000000800aULL,0x800000008000000aULL,
    0x8000000080008081ULL,0x8000000000008080ULL,0x0000000080000001ULL,0x8000000080008008ULL
};

__device__ __constant__ int KECCAK_RHO[24] = {
    1,3,6,10,15,21,28,36,45,55,2,14,27,41,56,8,25,43,62,18,39,61,20,44
};

__device__ __constant__ int KECCAK_PI[24] = {
    10,7,11,17,18,3,5,16,8,21,24,4,15,23,19,13,12,2,20,14,22,9,6,1
};

__device__ __noinline__ void keccak_f(uint64_t A[25]) {
    uint64_t C[5], D[5], B[25];
    for (int round = 0; round < 24; round++) {
        // Theta
        for (int x = 0; x < 5; x++)
            C[x] = A[x] ^ A[x+5] ^ A[x+10] ^ A[x+15] ^ A[x+20];
        for (int x = 0; x < 5; x++) {
            D[x] = C[(x+4)%5] ^ ((C[(x+1)%5] << 1) | (C[(x+1)%5] >> 63));
            for (int y = 0; y < 5; y++) A[x+5*y] ^= D[x];
        }
        // Rho and Pi
        uint64_t last = A[1];
        for (int i = 0; i < 24; i++) {
            int j = KECCAK_PI[i];
            B[0] = A[j];
            A[j] = (last << KECCAK_RHO[i]) | (last >> (64 - KECCAK_RHO[i]));
            last = B[0];
        }
        // Chi
        for (int y = 0; y < 5; y++) {
            for (int x = 0; x < 5; x++) B[x] = A[x+5*y];
            for (int x = 0; x < 5; x++)
                A[x+5*y] = B[x] ^ ((~B[(x+1)%5]) & B[(x+2)%5]);
        }
        // Iota
        A[0] ^= KECCAK_RC[round];
    }
}

// SHA3-256 of (prefix_bytes || data), used for onion checksum
// Computes SHA3-256(".onion checksum" || pubkey[32] || version[1])
// Total input: 15 + 32 + 1 = 48 bytes
// Rate for SHA3-256 = 136 bytes → fits in one block
__device__ __noinline__ void sha3_256_onion_checksum(const uint8_t pubkey[32], uint8_t out[32]) {
    uint64_t A[25] = {0};
    const uint8_t prefix[15] = {'.','o','n','i','o','n',' ','c','h','e','c','k','s','u','m'};
    // Input: prefix(15) || pubkey(32) || version(1) = 48 bytes
    // SHA3-256: rate=136, pad with 0x06 at byte 48, 0x80 at byte 135
    uint8_t block[136] = {0};
    for (int i = 0; i < 15; i++) block[i] = prefix[i];
    for (int i = 0; i < 32; i++) block[15+i] = pubkey[i];
    block[47] = 0x03;      // version byte
    block[48] = 0x06;      // SHA3 domain separation
    block[135] = 0x80;     // end of padding

    // XOR block into A (little-endian 64-bit lanes)
    for (int i = 0; i < 17; i++) { // 136/8 = 17 lanes
        uint64_t lane = 0;
        for (int b = 0; b < 8; b++)
            lane |= ((uint64_t)block[i*8+b]) << (8*b);
        A[i] ^= lane;
    }
    keccak_f(A);

    // Extract 32 bytes of output (little-endian)
    for (int i = 0; i < 4; i++) {
        for (int b = 0; b < 8; b++)
            out[i*8+b] = (A[i] >> (8*b)) & 0xff;
    }
}
