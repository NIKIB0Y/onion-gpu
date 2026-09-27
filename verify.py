#!/usr/bin/env python3
"""Independently verify onion-gpu key files.

Re-derives everything on the CPU with pure-Python Ed25519 -- no shared code
with the CUDA implementation -- and checks that the secret scalar really does
produce the published address.

    python3 verify.py [directory]

Exits non-zero if any key fails.
"""
import base64
import glob
import hashlib
import os
import stat
import sys

P = 2**255 - 19
D = -121665 * pow(121666, P - 2, P) % P


def add(p, q):
    x1, y1 = p
    x2, y2 = q
    k = D * x1 * x2 * y1 * y2 % P
    x3 = (x1 * y2 + x2 * y1) * pow(1 + k, P - 2, P) % P
    y3 = (y1 * y2 + x1 * x2) * pow(1 - k, P - 2, P) % P
    return (x3, y3)


def mul(p, n):
    q = (0, 1)
    while n:
        if n & 1:
            q = add(q, p)
        p = add(p, p)
        n >>= 1
    return q


def base_point():
    y = 4 * pow(5, P - 2, P) % P
    xx = (y * y - 1) * pow(D * y * y + 1, P - 2, P) % P
    x = pow(xx, (P + 3) // 8, P)
    if (x * x - xx) % P:
        x = x * pow(2, (P - 1) // 4, P) % P
    if x % 2:
        x = P - x
    return (x, y)


B = base_point()

PUB_HDR = b"== ed25519v1-public: type0 ==" + b"\0" * 3
SEC_HDR = b"== ed25519v1-secret: type0 ==" + b"\0" * 3


def encode_point(p):
    x, y = p
    return (y | ((x & 1) << 255)).to_bytes(32, "little")


def address(pub):
    ck = hashlib.sha3_256(b".onion checksum" + pub + b"\x03").digest()[:2]
    return base64.b32encode(pub + ck + b"\x03").decode().lower()


def check(base):
    name = os.path.basename(base)
    problems = []

    try:
        pub_raw = open(base + "_hs_ed25519_public_key", "rb").read()
        sec_raw = open(base + "_hs_ed25519_secret_key", "rb").read()
        host = open(base + "_hostname").read().strip()
    except OSError as e:
        return ["cannot read key files: %s" % e]

    if len(pub_raw) != 64 or pub_raw[:32] != PUB_HDR:
        problems.append("public key file has a bad header or length")
    if len(sec_raw) != 96 or sec_raw[:32] != SEC_HDR:
        problems.append("secret key file has a bad header or length")
    if problems:
        return problems

    pub = pub_raw[32:64]
    scalar_bytes = sec_raw[32:64]
    scalar = int.from_bytes(scalar_bytes, "little")

    if scalar_bytes[0] % 8 != 0 or scalar_bytes[31] & 0xC0 != 0x40:
        problems.append("scalar is not clamped -- Tor would alter it on load")

    if encode_point(mul(B, scalar)) != pub:
        problems.append("SECRET KEY DOES NOT MATCH PUBLIC KEY")

    addr = address(pub)
    if addr != name:
        problems.append("filename does not match the address derived from the "
                        "public key (%s)" % addr)
    if host != addr + ".onion":
        problems.append("hostname file says %r, expected %r" % (host, addr + ".onion"))

    mode = stat.S_IMODE(os.stat(base + "_hs_ed25519_secret_key").st_mode)
    if mode & 0o077:
        problems.append("secret key file is readable by others (mode %o)" % mode)

    return problems


def main():
    d = sys.argv[1] if len(sys.argv) > 1 else "."
    bases = sorted(f[: -len("_hs_ed25519_public_key")]
                   for f in glob.glob(os.path.join(d, "*_hs_ed25519_public_key")))
    if not bases:
        print("No key files found in %s" % d)
        return 1

    bad = 0
    for base in bases:
        problems = check(base)
        name = os.path.basename(base)
        if problems:
            bad += 1
            print("FAIL %s.onion" % name)
            for p in problems:
                print("     - %s" % p)
        else:
            print("OK   %s.onion" % name)

    print("\n%d key(s) checked, %d failed." % (len(bases), bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
