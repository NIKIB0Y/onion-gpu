#pragma once
#include <stdint.h>

// Field element GF(2^255-19), 10 limbs of 25/26 bits (ref10 style)
// Limbs 0,2,4,6,8 are 26-bit; limbs 1,3,5,7,9 are 25-bit
typedef int32_t fe[10];

__device__ void fe_0(fe h) {
    for (int i = 0; i < 10; i++) h[i] = 0;
}

__device__ void fe_1(fe h) {
    h[0] = 1;
    for (int i = 1; i < 10; i++) h[i] = 0;
}

__device__ void fe_copy(fe h, const fe f) {
    for (int i = 0; i < 10; i++) h[i] = f[i];
}

__device__ void fe_add(fe h, const fe f, const fe g) {
    for (int i = 0; i < 10; i++) h[i] = f[i] + g[i];
}

__device__ void fe_sub(fe h, const fe f, const fe g) {
    for (int i = 0; i < 10; i++) h[i] = f[i] - g[i];
}

__device__ void fe_neg(fe h, const fe f) {
    for (int i = 0; i < 10; i++) h[i] = -f[i];
}

__device__ void fe_frombytes(fe h, const uint8_t s[32]) {
    int64_t h0 = (int64_t)(s[0])        | ((int64_t)(s[1])<<8)  | ((int64_t)(s[2])<<16) | (((int64_t)(s[3])&0x3)<<24);
    int64_t h1 = ((int64_t)(s[3])>>2)   | ((int64_t)(s[4])<<6)  | ((int64_t)(s[5])<<14) | (((int64_t)(s[6])&0x7)<<22);
    int64_t h2 = ((int64_t)(s[6])>>3)   | ((int64_t)(s[7])<<5)  | ((int64_t)(s[8])<<13) | (((int64_t)(s[9])&0x1f)<<21);
    int64_t h3 = ((int64_t)(s[9])>>5)   | ((int64_t)(s[10])<<3) | ((int64_t)(s[11])<<11)| (((int64_t)(s[12])&0x3f)<<19);
    int64_t h4 = ((int64_t)(s[12])>>6)  | ((int64_t)(s[13])<<2) | ((int64_t)(s[14])<<10)| ((int64_t)(s[15])<<18);
    int64_t h5 = (int64_t)(s[16])       | ((int64_t)(s[17])<<8) | ((int64_t)(s[18])<<16)| (((int64_t)(s[19])&0x1)<<24);
    int64_t h6 = ((int64_t)(s[19])>>1)  | ((int64_t)(s[20])<<7) | ((int64_t)(s[21])<<15)| (((int64_t)(s[22])&0x7)<<23);
    int64_t h7 = ((int64_t)(s[22])>>3)  | ((int64_t)(s[23])<<5) | ((int64_t)(s[24])<<13)| (((int64_t)(s[25])&0x0f)<<21);
    int64_t h8 = ((int64_t)(s[25])>>4)  | ((int64_t)(s[26])<<4) | ((int64_t)(s[27])<<12)| (((int64_t)(s[28])&0x3f)<<20);
    int64_t h9 = ((int64_t)(s[28])>>6)  | ((int64_t)(s[29])<<2) | ((int64_t)(s[30])<<10)| (((int64_t)(s[31])&0x7f)<<18);
    h9 -= (int64_t)((s[31]>>7)*19)*((int64_t)1<<24); // reduce mod p (high bit = sign)
    h[0]=(int32_t)h0; h[1]=(int32_t)h1; h[2]=(int32_t)h2; h[3]=(int32_t)h3; h[4]=(int32_t)h4;
    h[5]=(int32_t)h5; h[6]=(int32_t)h6; h[7]=(int32_t)h7; h[8]=(int32_t)h8; h[9]=(int32_t)h9;
}

__device__ void fe_tobytes(uint8_t s[32], const fe h) {
    int32_t q = (19*h[9] + (1<<24)) >> 25;
    q = (h[0] + q) >> 26; q = (h[1] + q) >> 25; q = (h[2] + q) >> 26; q = (h[3] + q) >> 25;
    q = (h[4] + q) >> 26; q = (h[5] + q) >> 25; q = (h[6] + q) >> 26; q = (h[7] + q) >> 25;
    q = (h[8] + q) >> 26; q = (h[9] + q) >> 25;
    int32_t t[10];
    t[0] = h[0] + 19*q;
    int32_t carry = t[0] >> 26; t[1] = h[1] + carry; t[0] &= 0x3ffffff;
    carry = t[1] >> 25; t[2] = h[2] + carry; t[1] &= 0x1ffffff;
    carry = t[2] >> 26; t[3] = h[3] + carry; t[2] &= 0x3ffffff;
    carry = t[3] >> 25; t[4] = h[4] + carry; t[3] &= 0x1ffffff;
    carry = t[4] >> 26; t[5] = h[5] + carry; t[4] &= 0x3ffffff;
    carry = t[5] >> 25; t[6] = h[6] + carry; t[5] &= 0x1ffffff;
    carry = t[6] >> 26; t[7] = h[7] + carry; t[6] &= 0x3ffffff;
    carry = t[7] >> 25; t[8] = h[8] + carry; t[7] &= 0x1ffffff;
    carry = t[8] >> 26; t[9] = h[9] + carry; t[8] &= 0x3ffffff;
                                               t[9] &= 0x1ffffff;
    s[0]  = (uint8_t)(t[0]);
    s[1]  = (uint8_t)(t[0] >> 8);
    s[2]  = (uint8_t)(t[0] >> 16);
    s[3]  = (uint8_t)((t[0] >> 24) | (t[1] << 2));
    s[4]  = (uint8_t)(t[1] >> 6);
    s[5]  = (uint8_t)(t[1] >> 14);
    s[6]  = (uint8_t)((t[1] >> 22) | (t[2] << 3));
    s[7]  = (uint8_t)(t[2] >> 5);
    s[8]  = (uint8_t)(t[2] >> 13);
    s[9]  = (uint8_t)((t[2] >> 21) | (t[3] << 5));
    s[10] = (uint8_t)(t[3] >> 3);
    s[11] = (uint8_t)(t[3] >> 11);
    s[12] = (uint8_t)((t[3] >> 19) | (t[4] << 6));
    s[13] = (uint8_t)(t[4] >> 2);
    s[14] = (uint8_t)(t[4] >> 10);
    s[15] = (uint8_t)(t[4] >> 18);
    s[16] = (uint8_t)(t[5]);
    s[17] = (uint8_t)(t[5] >> 8);
    s[18] = (uint8_t)(t[5] >> 16);
    s[19] = (uint8_t)((t[5] >> 24) | (t[6] << 1));
    s[20] = (uint8_t)(t[6] >> 7);
    s[21] = (uint8_t)(t[6] >> 15);
    s[22] = (uint8_t)((t[6] >> 23) | (t[7] << 3));
    s[23] = (uint8_t)(t[7] >> 5);
    s[24] = (uint8_t)(t[7] >> 13);
    s[25] = (uint8_t)((t[7] >> 21) | (t[8] << 4));
    s[26] = (uint8_t)(t[8] >> 4);
    s[27] = (uint8_t)(t[8] >> 12);
    s[28] = (uint8_t)((t[8] >> 20) | (t[9] << 6));
    s[29] = (uint8_t)(t[9] >> 2);
    s[30] = (uint8_t)(t[9] >> 10);
    s[31] = (uint8_t)(t[9] >> 18);
}

__device__ void fe_mul(fe h, const fe f, const fe g) {
    int32_t f0=f[0],f1=f[1],f2=f[2],f3=f[3],f4=f[4],f5=f[5],f6=f[6],f7=f[7],f8=f[8],f9=f[9];
    int32_t g0=g[0],g1=g[1],g2=g[2],g3=g[3],g4=g[4],g5=g[5],g6=g[6],g7=g[7],g8=g[8],g9=g[9];
    int64_t g1_19=(int64_t)19*g1,g2_19=(int64_t)19*g2,g3_19=(int64_t)19*g3,g4_19=(int64_t)19*g4;
    int64_t g5_19=(int64_t)19*g5,g6_19=(int64_t)19*g6,g7_19=(int64_t)19*g7,g8_19=(int64_t)19*g8,g9_19=(int64_t)19*g9;
    int64_t f1_2=(int64_t)2*f1,f3_2=(int64_t)2*f3,f5_2=(int64_t)2*f5,f7_2=(int64_t)2*f7,f9_2=(int64_t)2*f9;
    int64_t h0=(int64_t)f0*g0+(int64_t)f1_2*g9_19+(int64_t)f2*g8_19+(int64_t)f3_2*g7_19+(int64_t)f4*g6_19+(int64_t)f5_2*g5_19+(int64_t)f6*g4_19+(int64_t)f7_2*g3_19+(int64_t)f8*g2_19+(int64_t)f9_2*g1_19;
    int64_t h1=(int64_t)f0*g1+(int64_t)f1*g0+(int64_t)f2*g9_19+(int64_t)f3*g8_19+(int64_t)f4*g7_19+(int64_t)f5*g6_19+(int64_t)f6*g5_19+(int64_t)f7*g4_19+(int64_t)f8*g3_19+(int64_t)f9*g2_19;
    int64_t h2=(int64_t)f0*g2+(int64_t)f1_2*g1+(int64_t)f2*g0+(int64_t)f3_2*g9_19+(int64_t)f4*g8_19+(int64_t)f5_2*g7_19+(int64_t)f6*g6_19+(int64_t)f7_2*g5_19+(int64_t)f8*g4_19+(int64_t)f9_2*g3_19;
    int64_t h3=(int64_t)f0*g3+(int64_t)f1*g2+(int64_t)f2*g1+(int64_t)f3*g0+(int64_t)f4*g9_19+(int64_t)f5*g8_19+(int64_t)f6*g7_19+(int64_t)f7*g6_19+(int64_t)f8*g5_19+(int64_t)f9*g4_19;
    int64_t h4=(int64_t)f0*g4+(int64_t)f1_2*g3+(int64_t)f2*g2+(int64_t)f3_2*g1+(int64_t)f4*g0+(int64_t)f5_2*g9_19+(int64_t)f6*g8_19+(int64_t)f7_2*g7_19+(int64_t)f8*g6_19+(int64_t)f9_2*g5_19;
    int64_t h5=(int64_t)f0*g5+(int64_t)f1*g4+(int64_t)f2*g3+(int64_t)f3*g2+(int64_t)f4*g1+(int64_t)f5*g0+(int64_t)f6*g9_19+(int64_t)f7*g8_19+(int64_t)f8*g7_19+(int64_t)f9*g6_19;
    int64_t h6=(int64_t)f0*g6+(int64_t)f1_2*g5+(int64_t)f2*g4+(int64_t)f3_2*g3+(int64_t)f4*g2+(int64_t)f5_2*g1+(int64_t)f6*g0+(int64_t)f7_2*g9_19+(int64_t)f8*g8_19+(int64_t)f9_2*g7_19;
    int64_t h7=(int64_t)f0*g7+(int64_t)f1*g6+(int64_t)f2*g5+(int64_t)f3*g4+(int64_t)f4*g3+(int64_t)f5*g2+(int64_t)f6*g1+(int64_t)f7*g0+(int64_t)f8*g9_19+(int64_t)f9*g8_19;
    int64_t h8=(int64_t)f0*g8+(int64_t)f1_2*g7+(int64_t)f2*g6+(int64_t)f3_2*g5+(int64_t)f4*g4+(int64_t)f5_2*g3+(int64_t)f6*g2+(int64_t)f7_2*g1+(int64_t)f8*g0+(int64_t)f9_2*g9_19;
    int64_t h9=(int64_t)f0*g9+(int64_t)f1*g8+(int64_t)f2*g7+(int64_t)f3*g6+(int64_t)f4*g5+(int64_t)f5*g4+(int64_t)f6*g3+(int64_t)f7*g2+(int64_t)f8*g1+(int64_t)f9*g0;
    int64_t carry;
    carry=h0>>26; h1+=carry; h0-=carry<<26;
    carry=h4>>26; h5+=carry; h4-=carry<<26;
    carry=h1>>25; h2+=carry; h1-=carry<<25;
    carry=h5>>25; h6+=carry; h5-=carry<<25;
    carry=h2>>26; h3+=carry; h2-=carry<<26;
    carry=h6>>26; h7+=carry; h6-=carry<<26;
    carry=h3>>25; h4+=carry; h3-=carry<<25;
    carry=h7>>25; h8+=carry; h7-=carry<<25;
    carry=h4>>26; h5+=carry; h4-=carry<<26;
    carry=h8>>26; h9+=carry; h8-=carry<<26;
    carry=h9>>25; h0+=carry*19; h9-=carry<<25;
    carry=h0>>26; h1+=carry; h0-=carry<<26;
    h[0]=(int32_t)h0; h[1]=(int32_t)h1; h[2]=(int32_t)h2; h[3]=(int32_t)h3; h[4]=(int32_t)h4;
    h[5]=(int32_t)h5; h[6]=(int32_t)h6; h[7]=(int32_t)h7; h[8]=(int32_t)h8; h[9]=(int32_t)h9;
}

__device__ void fe_sq(fe h, const fe f) { fe_mul(h, f, f); }

__device__ void fe_sq2(fe h, const fe f) {
    fe_sq(h, f);
    for (int i = 0; i < 10; i++) h[i] *= 2;
}

__device__ __noinline__ void fe_invert(fe out, const fe z) {
    fe t0, t1, t2, t3;
    fe_sq(t0, z);
    fe_sq(t1, t0); fe_sq(t1, t1);
    fe_mul(t1, z, t1);
    fe_mul(t0, t0, t1);
    fe_sq(t2, t0); fe_mul(t1, t1, t2);
    fe_sq(t2, t1);
    for (int i = 1; i < 5; i++) fe_sq(t2, t2);
    fe_mul(t1, t2, t1);
    fe_sq(t2, t1);
    for (int i = 1; i < 10; i++) fe_sq(t2, t2);
    fe_mul(t2, t2, t1);
    fe_sq(t3, t2);
    for (int i = 1; i < 20; i++) fe_sq(t3, t3);
    fe_mul(t2, t3, t2);
    fe_sq(t2, t2);
    for (int i = 1; i < 10; i++) fe_sq(t2, t2);
    fe_mul(t1, t2, t1);
    fe_sq(t2, t1);
    for (int i = 1; i < 50; i++) fe_sq(t2, t2);
    fe_mul(t2, t2, t1);
    fe_sq(t3, t2);
    for (int i = 1; i < 100; i++) fe_sq(t3, t3);
    fe_mul(t2, t3, t2);
    fe_sq(t2, t2);
    for (int i = 1; i < 50; i++) fe_sq(t2, t2);
    fe_mul(t1, t2, t1);
    fe_sq(t1, t1);
    for (int i = 1; i < 5; i++) fe_sq(t1, t1);
    fe_mul(out, t1, t0);
}

__device__ void fe_pow22523(fe out, const fe z) {
    fe t0, t1, t2;
    fe_sq(t0, z);
    fe_sq(t1, t0); fe_sq(t1, t1);
    fe_mul(t1, z, t1);
    fe_mul(t0, t0, t1);
    fe_sq(t0, t0);
    fe_mul(t0, t1, t0);
    fe_sq(t1, t0);
    for (int i = 1; i < 5; i++) fe_sq(t1, t1);
    fe_mul(t0, t1, t0);
    fe_sq(t1, t0);
    for (int i = 1; i < 10; i++) fe_sq(t1, t1);
    fe_mul(t1, t1, t0);
    fe_sq(t2, t1);
    for (int i = 1; i < 20; i++) fe_sq(t2, t2);
    fe_mul(t1, t2, t1);
    fe_sq(t1, t1);
    for (int i = 1; i < 10; i++) fe_sq(t1, t1);
    fe_mul(t0, t1, t0);
    fe_sq(t1, t0);
    for (int i = 1; i < 50; i++) fe_sq(t1, t1);
    fe_mul(t1, t1, t0);
    fe_sq(t2, t1);
    for (int i = 1; i < 100; i++) fe_sq(t2, t2);
    fe_mul(t1, t2, t1);
    fe_sq(t1, t1);
    for (int i = 1; i < 50; i++) fe_sq(t1, t1);
    fe_mul(t0, t1, t0);
    fe_sq(t0, t0);
    fe_sq(t0, t0);
    fe_mul(out, t0, z);
}

__device__ void fe_cmov(fe f, const fe g, uint32_t b) {
    uint32_t mask = -(int32_t)b;
    for (int i = 0; i < 10; i++) {
        int32_t x = f[i] ^ g[i];
        x &= (int32_t)mask;
        f[i] ^= x;
    }
}

// -------------------------------------------------------------------------
// Canonicalise limbs: round-trip through the byte encoding so every limb is
// non-negative and minimal ([0,2^26) even, [0,2^25) odd).
//
// Load-bearing for the hot loop's overflow margin: ge_madd() multiplies the
// cached step constants into every chain multiply, and fe_mul()'s int64
// accumulator only has room for a bounded limb widening (see ge_madd).
// -------------------------------------------------------------------------
__device__ void fe_canonicalize(fe h) {
    uint8_t s[32];
    fe_tobytes(s, h);
    fe_frombytes(h, s);
}

// -------------------------------------------------------------------------
// Low 8 bytes of the canonical encoding, packed big-endian (byte 0 in the
// most significant position).
//
// The v3 onion address is base32 of (pubkey || checksum || version) taken
// MSB-first over the byte stream, so address character i occupies bit
// positions [5i, 5i+5) of this word: character 0 is v >> 59.  That makes a
// prefix test on up to 12 characters a single masked 64-bit compare, with no
// base32 encoding in the hot loop.
//
// Only limbs 0..2 of the reduction are needed, but q depends on all ten.
// -------------------------------------------------------------------------
__device__ __forceinline__ uint64_t fe_low8_be(const fe h) {
    int32_t q = (19*h[9] + (1<<24)) >> 25;
    q = (h[0] + q) >> 26; q = (h[1] + q) >> 25; q = (h[2] + q) >> 26; q = (h[3] + q) >> 25;
    q = (h[4] + q) >> 26; q = (h[5] + q) >> 25; q = (h[6] + q) >> 26; q = (h[7] + q) >> 25;
    q = (h[8] + q) >> 26; q = (h[9] + q) >> 25;

    int32_t t0 = h[0] + 19*q;
    int32_t carry = t0 >> 26; int32_t t1 = h[1] + carry; t0 &= 0x3ffffff;
    carry = t1 >> 25;        int32_t t2 = h[2] + carry; t1 &= 0x1ffffff;

    uint32_t s0 = (uint32_t)(t0)       & 0xff;
    uint32_t s1 = (uint32_t)(t0 >> 8)  & 0xff;
    uint32_t s2 = (uint32_t)(t0 >> 16) & 0xff;
    uint32_t s3 = (uint32_t)((t0 >> 24) | (t1 << 2)) & 0xff;
    uint32_t s4 = (uint32_t)(t1 >> 6)  & 0xff;
    uint32_t s5 = (uint32_t)(t1 >> 14) & 0xff;
    uint32_t s6 = (uint32_t)((t1 >> 22) | (t2 << 3)) & 0xff;
    uint32_t s7 = (uint32_t)(t2 >> 5)  & 0xff;

    return ((uint64_t)s0 << 56) | ((uint64_t)s1 << 48) | ((uint64_t)s2 << 40) |
           ((uint64_t)s3 << 32) | ((uint64_t)s4 << 24) | ((uint64_t)s5 << 16) |
           ((uint64_t)s6 <<  8) | ((uint64_t)s7);
}
