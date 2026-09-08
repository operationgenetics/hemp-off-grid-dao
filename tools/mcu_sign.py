#!/usr/bin/env python3
"""
Stand-in for the Roomie robot's hybrid-PQC MCU, for tests only.

  mcu_sign.py pk                  -> the ML-DSA-65 public key, hex
  mcu_sign.py ahat                -> ExpandA(rho), hex (30720 bytes)
  mcu_sign.py sign <digest_hex>   -> ML-DSA-65 signature over the 32-byte digest, hex

The real MCU holds the secret key in hardware behind a biometric gate and never
exposes it. The seed here is fixed so tests are reproducible.
"""
import sys, hashlib
sys.path.insert(0, 'tools')
from dilithium_py.ml_dsa import ML_DSA_65
import mldsa_ref as R

SEED = bytes.fromhex('a5' * 32)
pk, sk = ML_DSA_65.key_derive(SEED)

cmd = sys.argv[1]
if cmd == 'pk':
    print('0x' + pk.hex())
elif cmd == 'tr':
    print('0x' + hashlib.shake_256(pk).digest(64).hex())
elif cmd == 'ahat':
    rho, _ = R.pk_decode(pk)
    A = R.expand_a(rho)
    out = bytearray()
    for r in range(R.K):
        for s in range(R.L):
            for c in A[r][s]:
                out += c.to_bytes(4, 'big')
    print('0x' + bytes(out).hex())
elif cmd == 'sign':
    digest = bytes.fromhex(sys.argv[2].removeprefix('0x'))
    assert len(digest) == 32, 'digest must be 32 bytes'
    sig = ML_DSA_65.sign(sk, digest, deterministic=True)
    assert ML_DSA_65.verify(pk, digest, sig)
    print('0x' + sig.hex())
else:
    raise SystemExit('unknown command')
