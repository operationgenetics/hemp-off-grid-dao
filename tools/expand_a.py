#!/usr/bin/env python3
"""ExpandA(rho) for a given ML-DSA-65 public key, as 30720 hex bytes.

Convenience only: MLDSA65Verifier.commitMatrixChunk recomputes every coefficient
on-chain and reverts on the first mismatch, so a wrong answer here cannot install a
forged matrix — it can only waste gas.
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mldsa_ref as R

pk = bytes.fromhex(sys.argv[1].removeprefix('0x'))
if len(pk) != 1952:
    raise SystemExit('public key must be 1952 bytes for ML-DSA-65')
rho, _ = R.pk_decode(pk)
A = R.expand_a(rho)
out = bytearray()
for r in range(R.K):
    for s in range(R.L):
        for c in A[r][s]:
            out += c.to_bytes(4, 'big')
print('0x' + bytes(out).hex())
