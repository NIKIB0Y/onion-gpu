#pragma once
#include "fe25519.cuh"

typedef struct { fe X, Y, Z, T; } ge_p3;
typedef struct { fe X, Y, Z; } ge_p2;
// Completed: X3=X*T, Y3=Y*Z, Z3=Z*T, T3=X*Y
typedef struct { fe X, Y, Z, T; } ge_p1p1;

// Ed25519 base point compressed (little-endian y with x-sign in high bit)
// y = 4/5 mod p = 0x6666...6658, x positive → high bit = 0
__device__ __constant__ uint8_t BASE_POINT_Y_BYTES[32] = {
    0x58,0x66,0x66,0x66,0x66,0x66,0x66,0x66,
    0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,
    0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,
    0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66
};
__device__ __constant__ uint8_t BASE_POINT_X_BYTES[32] = {
    0x1a,0xd5,0x25,0x8f,0x60,0x2d,0x56,0xc9,
    0xb2,0xa7,0x25,0x95,0x60,0xc7,0x2c,0x69,
    0x5c,0xdc,0xd6,0xfd,0x31,0xe2,0xa4,0xc0,
    0xfe,0x53,0x6e,0xcd,0xd3,0x36,0x69,0x21
};

// 2*d = 2*(-121665/121666 mod p) in limb form
__device__ __forceinline__ void load_2d(fe h) {
    h[0]=-21827239; h[1]=-5839606;  h[2]=-30745221; h[3]=13898782; h[4]=229458;
    h[5]=15978800;  h[6]=-12551817; h[7]=-6495438;  h[8]=29715968; h[9]=9444199;
}

__device__ void ge_p3_0(ge_p3 *h) {
    fe_0(h->X); fe_1(h->Y); fe_1(h->Z); fe_0(h->T);
}

__device__ void ge_p1p1_to_p3(ge_p3 *r, const ge_p1p1 *p) {
    fe_mul(r->X, p->X, p->T);
    fe_mul(r->Y, p->Y, p->Z);
    fe_mul(r->Z, p->Z, p->T);
    fe_mul(r->T, p->X, p->Y);
}

__device__ void ge_p3_to_p2(ge_p2 *r, const ge_p3 *p) {
    fe_copy(r->X, p->X); fe_copy(r->Y, p->Y); fe_copy(r->Z, p->Z);
}

__device__ void ge_p2_dbl(ge_p1p1 *r, const ge_p2 *p) {
    fe t0;
    fe_sq(r->X, p->X);
    fe_sq(r->Z, p->Y);
    fe_sq2(r->T, p->Z);
    fe_add(r->Y, p->X, p->Y);
    fe_sq(t0, r->Y);
    fe_add(r->Y, r->Z, r->X);
    fe_sub(r->Z, r->Z, r->X);
    fe_sub(r->X, t0, r->Y);
    fe_sub(r->T, r->T, r->Z);
}

__device__ void ge_p3_dbl(ge_p1p1 *r, const ge_p3 *p) {
    ge_p2 q; ge_p3_to_p2(&q, p); ge_p2_dbl(r, &q);
}

// Extended point addition: r = p + q (both in extended coords)
// Uses the formula from https://hyperelliptic.org/EFD/g1p/auto-twisted-extended.html
__device__ void ge_add(ge_p1p1 *r, const ge_p3 *p, const ge_p3 *q) {
    fe A, B, C, D, E, F, G, H, k;
    fe_sub(A, p->Y, p->X); fe_sub(E, q->Y, q->X); fe_mul(A, A, E);
    fe_add(B, p->Y, p->X); fe_add(E, q->Y, q->X); fe_mul(B, B, E);
    load_2d(k);
    fe_mul(C, p->T, q->T); fe_mul(C, C, k);
    fe_mul(D, p->Z, q->Z); fe_add(D, D, D);
    fe_sub(E, B, A);
    fe_sub(F, D, C);
    fe_add(G, D, C);
    fe_add(H, B, A);
    // x = (r->X*r->T)/(r->Z*r->T) = E*F/(G*F) = E/G, y = H*G/(G*F) = H/F
    fe_copy(r->X, E); fe_copy(r->Y, H); fe_copy(r->Z, G); fe_copy(r->T, F);
}

__device__ void ge_init_base(ge_p3 *B) {
    fe_frombytes(B->X, BASE_POINT_X_BYTES);
    fe_frombytes(B->Y, BASE_POINT_Y_BYTES);
    fe_1(B->Z);
    fe_mul(B->T, B->X, B->Y);
}

// Scalar multiplication: r = s * BasePoint  (MSB-first double-and-add)
// s is 32 bytes little-endian scalar
__device__ __noinline__ void ge_scalarmult_base(ge_p3 *r, const uint8_t s[32]) {
    ge_p3 B;
    ge_init_base(&B);
    ge_p3_0(r);

    for (int i = 255; i >= 0; i--) {
        ge_p1p1 tmp;
        ge_p3_dbl(&tmp, r);
        ge_p1p1_to_p3(r, &tmp);

        int bit = (s[i / 8] >> (i % 8)) & 1;
        if (bit) {
            ge_p1p1 tmp2;
            ge_add(&tmp2, r, &B);
            ge_p1p1_to_p3(r, &tmp2);
        }
    }
}

// Encode a ge_p3 point as a 32-byte public key
__device__ void ge_p3_tobytes(uint8_t pubkey[32], const ge_p3 *p) {
    fe recip, x, y;
    fe_invert(recip, p->Z);
    fe_mul(x, p->X, recip);
    fe_mul(y, p->Y, recip);
    fe_tobytes(pubkey, y);
    uint8_t xbytes[32];
    fe_tobytes(xbytes, x);
    pubkey[31] |= (xbytes[0] & 1) << 7;
}

// -------------------------------------------------------------------------
// Cached affine point: (y-x, y+x, 2*d*x*y) for a point with Z = 1.
// Limbs are canonical (see ge_cached_from_p3).
// -------------------------------------------------------------------------
typedef struct { fe YmX, YpX, T2d; } ge_cached;

// Build the cached form of a projective point: normalise to affine, then
// canonicalise every limb.  One inversion, done once at startup.
__device__ void ge_cached_from_p3(ge_cached *c, const ge_p3 *p) {
    fe recip, x, y, t;
    fe_invert(recip, p->Z);
    fe_mul(x, p->X, recip);
    fe_mul(y, p->Y, recip);
    fe_canonicalize(x);
    fe_canonicalize(y);

    fe_sub(c->YmX, y, x);
    fe_add(c->YpX, y, x);
    fe_mul(t, x, y);
    fe k; load_2d(k);
    fe_mul(c->T2d, t, k);

    fe_canonicalize(c->YmX);
    fe_canonicalize(c->YpX);
    fe_canonicalize(c->T2d);
}

// -------------------------------------------------------------------------
// Mixed addition r = p + q with q cached and affine (Z_q = 1), giving the
// "completed" coordinates (E:H:G:F).  Because Z_q = 1, D = 2*Z_p*Z_q needs no
// multiply, so this is 3 muls; with the 4 of ge_p1p1_to_p3 the step is 7 muls
// total, the known optimum for mixed addition on a = -1 twisted Edwards
// (madd-2008-hwcd-3).
//
// Limb growth, in units of the fe_mul output bound (even limbs < 2^26, odd
// < 2^25).  fe_mul's int64 accumulator holds 124.5 * 2^52 * (widening of f) *
// (widening of g), so the product of the two widening factors must stay under
// ~16.9:
//     A,B,C   = fe_mul outputs                        -> 1
//     Y-X     = difference of two 1s                  -> 1
//     D = 2Z                                          -> 2
//     E = B-A -> 1     H = B+A -> 2
//     F = D-C -> 3     G = D+C -> 3
// The four products in ge_p1p1_to_p3 are then E*F (3), H*G (6), F*G (9) and
// E*H (2).  Worst case 9, so ~2^62.1 of the 2^63 available.
// -------------------------------------------------------------------------
__device__ __forceinline__ void ge_madd(ge_p1p1 *r, const ge_p3 *p, const ge_cached *q) {
    fe A, B, C, D, t;
    fe_sub(t, p->Y, p->X); fe_mul(A, t, q->YmX);
    fe_add(t, p->Y, p->X); fe_mul(B, t, q->YpX);
    fe_mul(C, p->T, q->T2d);
    fe_add(D, p->Z, p->Z);
    fe_sub(r->X, B, A);   // E
    fe_add(r->Y, B, A);   // H
    fe_add(r->Z, D, C);   // G
    fe_sub(r->T, D, C);   // F
}
