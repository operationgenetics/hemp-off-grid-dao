"""
ML-DSA-65 (FIPS 204) verification reference, written with only the operations that
can be ported to the EVM. Cross-checked against dilithium-py on real signatures.
Used to generate per-layer known-answer tests for the Solidity implementation.
"""
import hashlib

Q = 8380417
N = 256
D = 13
K, L = 6, 5
TAU = 49
BETA = 196
GAMMA1 = 1 << 19
GAMMA2 = (Q - 1) // 32          # 261888
OMEGA = 55
CTILDE = 48                     # lambda/4 for ML-DSA-65

def shake128(b, n): return hashlib.shake_128(b).digest(n)
def shake256(b, n): return hashlib.shake_256(b).digest(n)

# ---- NTT (plain modular arithmetic; EVM has native MULMOD) ----
ZETA = 1753
def _brv(i, bits=8): return int(format(i, f'0{bits}b')[::-1], 2)
ZETAS = [pow(ZETA, _brv(i), Q) for i in range(256)]

def ntt(a):
    a = a[:]; k = 0; ln = 128
    while ln >= 1:
        start = 0
        while start < 256:
            k += 1; z = ZETAS[k]
            for j in range(start, start + ln):
                t = (z * a[j + ln]) % Q
                a[j + ln] = (a[j] - t) % Q
                a[j] = (a[j] + t) % Q
            start += 2 * ln
        ln >>= 1
    return a

def intt(a):
    a = a[:]; k = 256; ln = 1
    while ln <= 128:
        start = 0
        while start < 256:
            k -= 1; z = (-ZETAS[k]) % Q
            for j in range(start, start + ln):
                t = a[j]
                a[j] = (t + a[j + ln]) % Q
                a[j + ln] = (z * (t - a[j + ln])) % Q
            start += 2 * ln
        ln <<= 1
    f = 8347681  # 256^-1 * 2^32 ... plain: inverse of 256 mod Q, folded below
    f = pow(256, Q - 2, Q)
    return [(x * f) % Q for x in a]

def poly_mul_ntt(a, b): return [(x * y) % Q for x, y in zip(a, b)]
def poly_add(a, b): return [(x + y) % Q for x, y in zip(a, b)]
def poly_sub(a, b): return [(x - y) % Q for x, y in zip(a, b)]

# ---- bit unpacking ----
def bits(data):
    for byte in data:
        for i in range(8):
            yield (byte >> i) & 1

def unpack_bits(data, width, count):
    out, acc, nb, it = [], 0, 0, iter(data)
    bitbuf = 0; nbits = 0
    for byte in data:
        bitbuf |= byte << nbits; nbits += 8
        while nbits >= width and len(out) < count:
            out.append(bitbuf & ((1 << width) - 1))
            bitbuf >>= width; nbits -= width
    return out[:count]

# ---- ML-DSA pieces ----
def pk_decode(pk):
    rho = pk[:32]
    t1 = []
    off = 32
    for i in range(K):
        chunk = pk[off:off + 320]; off += 320
        t1.append(unpack_bits(chunk, 10, 256))
    return rho, t1

def sig_decode(sig):
    ct = sig[:CTILDE]
    off = CTILDE
    z = []
    for i in range(L):
        chunk = sig[off:off + 640]; off += 640
        raw = unpack_bits(chunk, 20, 256)
        z.append([GAMMA1 - v for v in raw])
    y = sig[off:off + OMEGA + K]
    h = [[0] * 256 for _ in range(K)]
    idx = 0
    for i in range(K):
        end = y[OMEGA + i]
        if end < idx or end > OMEGA: return None
        first = idx
        while idx < end:
            if idx > first and y[idx - 1] >= y[idx]: return None
            h[i][y[idx]] = 1
            idx += 1
    for i in range(idx, OMEGA):
        if y[i] != 0: return None
    return ct, z, h

def coeff_from_three_bytes(b0, b1, b2):
    z = b0 | (b1 << 8) | ((b2 & 0x7F) << 16)
    return z if z < Q else None

def rej_ntt_poly(seed):
    x = hashlib.shake_128(seed)
    buf = x.digest(168 * 6)
    out, i = [], 0
    while len(out) < 256:
        if i + 3 > len(buf):
            buf = x.digest(len(buf) + 168 * 4)
        c = coeff_from_three_bytes(buf[i], buf[i + 1], buf[i + 2]); i += 3
        if c is not None: out.append(c)
    return out

def expand_a(rho):
    return [[rej_ntt_poly(rho + bytes([s, r])) for s in range(L)] for r in range(K)]

def sample_in_ball(ct):
    x = hashlib.shake_256(ct)
    buf = x.digest(136 * 3)
    c = [0] * 256
    signs = int.from_bytes(buf[:8], 'little')
    pos = 8
    for i in range(256 - TAU, 256):
        while True:
            j = buf[pos]; pos += 1
            if j <= i: break
        c[i] = c[j]
        c[j] = (Q - 1) if ((signs >> (i - (256 - TAU))) & 1) else 1
    return c

def decompose(r):
    rp = r % Q
    r0 = rp % (2 * GAMMA2)
    if r0 > GAMMA2: r0 -= 2 * GAMMA2
    if rp - r0 == Q - 1: return 0, r0 - 1
    return (rp - r0) // (2 * GAMMA2), r0

def use_hint(h, r):
    m = (Q - 1) // (2 * GAMMA2)   # 16
    r1, r0 = decompose(r)
    if h == 1:
        return (r1 + 1) % m if r0 > 0 else (r1 - 1) % m
    return r1

def w1_encode(w1):
    out = bytearray()
    acc = 0; nb = 0
    for poly in w1:
        for c in poly:
            acc |= c << nb; nb += 4
            while nb >= 8:
                out.append(acc & 0xFF); acc >>= 8; nb -= 8
    return bytes(out)

def verify(pk, msg, sig, ctx=b''):
    if len(pk) != 1952 or len(sig) != 3309: return False
    rho, t1 = pk_decode(pk)
    dec = sig_decode(sig)
    if dec is None: return False
    ct, z, h = dec

    for p in z:
        for c in p:
            cc = c if c <= Q // 2 else c - Q
            if abs(cc) >= GAMMA1 - BETA: return False
    if sum(sum(p) for p in h) > OMEGA: return False

    A = expand_a(rho)
    tr = shake256(pk, 64)
    mp = bytes([0]) + bytes([len(ctx)]) + ctx + msg
    mu = shake256(tr + mp, 64)
    c = sample_in_ball(ct)

    chat = ntt(c)
    zhat = [ntt(p) for p in z]
    t1hat = [ntt([(v << D) % Q for v in p]) for p in t1]

    w = []
    for i in range(K):
        acc = [0] * 256
        for j in range(L):
            acc = poly_add(acc, poly_mul_ntt(A[i][j], zhat[j]))
        acc = poly_sub(acc, poly_mul_ntt(chat, t1hat[i]))
        w.append(intt(acc))

    w1 = [[use_hint(h[i][j], w[i][j]) for j in range(256)] for i in range(K)]
    ct2 = shake256(mu + w1_encode(w1), CTILDE)
    return ct2 == ct
