// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "./Keccak.sol";

/**
 * @title MLDSA65
 * @notice ML-DSA-65 (FIPS 204) signature verification for the EVM.
 *
 * @dev Arithmetic is plain modular arithmetic over Z_q with q = 8380417, using the
 *      EVM's native MULMOD/ADDMOD opcodes. Montgomery form buys nothing here: MULMOD
 *      costs 8 gas, which is cheaper than a hand-written Montgomery reduction, and it
 *      removes an entire class of representation bugs.
 *
 *      The k*l expanded matrix A-hat is NOT recomputed here. ExpandA depends only on
 *      rho, a fixed part of the public key, so it is identical on every verification;
 *      recomputing it costs ~28.5M gas and does not fit in an Arbitrum block. It is
 *      instead passed in, having been committed and proven on-chain once. See
 *      MLDSA65Verifier.
 */
library MLDSA65 {
    uint256 internal constant Q = 8380417;
    uint256 internal constant N = 256;
    uint256 internal constant D = 13;
    uint256 internal constant K = 6;
    uint256 internal constant L = 5;
    uint256 internal constant TAU = 49;
    uint256 internal constant BETA = 196;
    uint256 internal constant GAMMA1 = 524288;      // 2^19
    uint256 internal constant GAMMA2 = 261888;      // (q-1)/32
    uint256 internal constant OMEGA = 55;
    uint256 internal constant CTILDE = 48;          // lambda/4
    uint256 internal constant N_INV = 8347681;     // 256^-1 mod q

    uint256 internal constant PK_BYTES = 1952;
    uint256 internal constant SIG_BYTES = 3309;
    uint256 internal constant POLY_BYTES = 1024;    // 256 coefficients, 4 bytes each
    uint256 internal constant MATRIX_BYTES = 30720; // K*L*POLY_BYTES

    /// @dev zeta^brv(i) mod q for i in 0..255, four big-endian bytes each.
    function zetas() internal pure returns (bytes memory) {
        return hex"0000000100495e020039756700396569004f062b0053df73004fe033004f066b0076b1ae00360dd50028edb000207fe4003972830070894a00088192006d3dc8004c72940041e0b40028a3d20066528a004a18a700794034000a52ee006b7d81004e9f1d001a2877002571df001649ee007611bd00492bb7002af6970022d8d50036f72a0030911e0029d13f004926730050685f002010a2003887f70011b2c3000603a4000e2bed0010b72c004a5f35001f9d1500428cd4003177f40020e61200341c1d001ad873007366810049553f003952f60062564a0065ad0500439a1c0053aa5f0030b62200087f38003b0e6d002c83da001c496e00330e2b001c5b70002ee3f100137eb90057a930003ac6ef003fd54c004eb2ea00503ee1007bb175002648b4001ef256001d90a20045a6d4002ae59b0052589c006ef1f5003f72880017510200075d59001187ba0052aca900773e9e000296d8002592ec004cff1200404ce8004aa582001e54e6004f16c1001a7e790003978f004e48170031b859005884cc001b4827005b63d0005d787a0035225e00400c7e006c09d1005bd532006bc4d300258ecb002e534c00097a6c003b8820006d285c002ca4f800337caa0014b2a0005585360028f1860055795d004af67000234a860075e8260078de660005528c007adf59000f6e17005bf3da00459b7e00628b34005dbecb001a9e7b000006d9006257c500574b3c0069a8ef002898380064b5fe007ef8f5002a4e7800120a23000154a80009b7ff00435e8700437ff8005cd5b4004dc04e004728af007f735d000c8d0d000f66d5005a6d800061ab9800185d9600437f310046829800662960004bd5790028de0600465d8d0049b0e30009b434007c0db3005a68b000409ba90064d3d50021762a0065859100246e390048c39b007bc759004f585900392db2002309230012eb6700454df20030c31c002854240013232e007faf80002dbfcb00022a0b007e832c0026587a006b337500095b76006be1cc005e061e0078e00d00628c37003da604004ae53c001f1d68006330bb007361b8005ea06c00671ac700201fc6005ba4ff0060d7720008f201006de02400080e6d0056038e00695688001e6d3e002603bd006a9dfa0007c017006dbfd40074d0bd0063e1e300519573007ab60d002867ba002decd40058018c003f4cf5000b700900427e23003cbd370027333300673957001a4b5d00196926001ef2060011c14e004c76c8003cf42f007fb19a006af66c002e1669003352d6000347600008526000741e78002f6316006f0a110007c0f100776d0b000d1ff000345824000223d40068c559005e8885002faa320023fc65005e69420051e0ed0065adb3002ca5e60079e1fe007b40640035e1dd00433aac00464ade001cfe140073f1ce0010170e0074b6d7";
    }

    /*//////////////////////////////////////////////////////////////
                            NUMBER THEORETIC TRANSFORM
    //////////////////////////////////////////////////////////////*/

    /// @notice In-place forward NTT, Cooley-Tukey, bit-reversed zeta order.
    function ntt(uint256[256] memory a) internal pure {
        bytes memory zt = zetas();
        assembly ("memory-safe") {
            let zp := add(zt, 32)
            let k := 0
            for { let len := 128 } gt(len, 0) { len := shr(1, len) } {
                for { let start := 0 } lt(start, 256) { start := add(start, shl(1, len)) } {
                    k := add(k, 1)
                    let z := shr(224, mload(add(zp, shl(2, k))))
                    let end := add(start, len)
                    for { let j := start } lt(j, end) { j := add(j, 1) } {
                        let pj := add(a, shl(5, j))
                        let pl := add(a, shl(5, add(j, len)))
                        let t := mulmod(z, mload(pl), 8380417)
                        let u := mload(pj)
                        mstore(pl, addmod(u, sub(8380417, t), 8380417))
                        mstore(pj, addmod(u, t, 8380417))
                    }
                }
            }
        }
    }

    /// @notice In-place inverse NTT, Gentleman-Sande, with the 1/256 scaling folded in.
    function intt(uint256[256] memory a) internal pure {
        bytes memory zt = zetas();
        assembly ("memory-safe") {
            let zp := add(zt, 32)
            let k := 256
            for { let len := 1 } lt(len, 256) { len := shl(1, len) } {
                for { let start := 0 } lt(start, 256) { start := add(start, shl(1, len)) } {
                    k := sub(k, 1)
                    let z := sub(8380417, shr(224, mload(add(zp, shl(2, k)))))
                    let end := add(start, len)
                    for { let j := start } lt(j, end) { j := add(j, 1) } {
                        let pj := add(a, shl(5, j))
                        let pl := add(a, shl(5, add(j, len)))
                        let t := mload(pj)
                        let v := mload(pl)
                        mstore(pj, addmod(t, v, 8380417))
                        mstore(pl, mulmod(z, addmod(t, sub(8380417, v), 8380417), 8380417))
                    }
                }
            }
            for { let j := 0 } lt(j, 256) { j := add(j, 1) } {
                let pj := add(a, shl(5, j))
                mstore(pj, mulmod(mload(pj), 8347681, 8380417))
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 BIT UNPACKING
    //////////////////////////////////////////////////////////////*/

    /// @dev Little-endian 32-bit read at byte offset `off` within `d`.
    ///      `byte(i, w)` extracts the i-th byte counting from the most significant,
    ///      which is the byte at `off + i` — masks by bit position are easy to get
    ///      wrong here, and did not survive testing.
    function _le32(bytes memory d, uint256 off) private pure returns (uint256 v) {
        assembly ("memory-safe") {
            let w := mload(add(add(d, 32), off))
            v := or(
                or(byte(0, w), shl(8, byte(1, w))),
                or(shl(16, byte(2, w)), shl(24, byte(3, w)))
            )
        }
    }

    /// @notice Unpack 256 coefficients of `width` bits each (width <= 20).
    function unpackBits(bytes memory src, uint256 off, uint256 width, uint256[256] memory out)
        internal
        pure
    {
        uint256 mask = (1 << width) - 1;
        unchecked {
            for (uint256 i = 0; i < 256; i++) {
                uint256 bit = i * width;
                out[i] = (_le32(src, off + (bit >> 3)) >> (bit & 7)) & mask;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                                  SAMPLING
    //////////////////////////////////////////////////////////////*/

    /// @notice SampleInBall: a sparse polynomial with exactly TAU coefficients in {1,-1}.
    function sampleInBall(bytes memory ctilde, uint256[256] memory c) internal pure {
        Keccak.XOF memory x = Keccak.newXof(Keccak.RATE_256);
        Keccak.absorb(x, ctilde);

        bytes memory head = Keccak.squeeze(x, 8);
        uint256 signs = 0;
        unchecked {
            for (uint256 i = 0; i < 8; i++) signs |= uint256(uint8(head[i])) << (8 * i);
        }

        unchecked {
            for (uint256 i = 256 - TAU; i < 256; i++) {
                uint256 j;
                while (true) {
                    j = uint8(Keccak.squeeze(x, 1)[0]);
                    if (j <= i) break;
                }
                c[i] = c[j];
                c[j] = ((signs >> (i - (256 - TAU))) & 1) == 1 ? Q - 1 : 1;
            }
        }
    }

    /// @notice RejNTTPoly: rejection-sample one A-hat polynomial from rho || s || r.
    function rejNttPoly(bytes memory seed, uint256[256] memory out) internal pure {
        Keccak.XOF memory x = Keccak.newXof(Keccak.RATE_128);
        Keccak.absorb(x, seed);

        uint256 filled = 0;
        while (filled < 256) {
            bytes memory b = Keccak.squeeze(x, 3);
            uint256 z = uint256(uint8(b[0]))
                | (uint256(uint8(b[1])) << 8)
                | ((uint256(uint8(b[2])) & 0x7F) << 16);
            if (z < Q) {
                out[filled] = z;
                unchecked { filled++; }
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                              HINTS AND ENCODING
    //////////////////////////////////////////////////////////////*/

    /// @dev Decompose r into (r1, r0) with r = r1*2*GAMMA2 + r0, r0 centred.
    ///      Returns r0 shifted by Q so it stays unsigned; caller compares against Q.
    function decompose(uint256 r) internal pure returns (uint256 r1, int256 r0) {
        unchecked {
            uint256 rp = r % Q;
            int256 t = int256(rp % (2 * GAMMA2));
            if (t > int256(GAMMA2)) t -= int256(2 * GAMMA2);
            if (int256(rp) - t == int256(Q) - 1) return (0, t - 1);
            return (uint256((int256(rp) - t) / int256(2 * GAMMA2)), t);
        }
    }

    function useHint(uint256 h, uint256 r) internal pure returns (uint256) {
        unchecked {
            uint256 m = (Q - 1) / (2 * GAMMA2); // 16
            (uint256 r1, int256 r0) = decompose(r);
            if (h == 1) {
                if (r0 > 0) return (r1 + 1) % m;
                return (r1 + m - 1) % m;
            }
            return r1;
        }
    }

    /*//////////////////////////////////////////////////////////////
                                   VERIFY
    //////////////////////////////////////////////////////////////*/

    /// @notice Full ML-DSA-65 verification.
    /// @param aHat  Expanded matrix A-hat, MATRIX_BYTES of big-endian uint32 coefficients,
    ///              row-major [r][s]. Must have been committed as ExpandA(rho).
    /// @param tr    Committed H(pk, 64). Derived solely from pk, so it is fixed for the
    ///              life of the key; recomputing it costs ~2M gas per verification.
    /// @param pk    1952-byte ML-DSA-65 public key (rho || t1).
    /// @param message The signed message.
    /// @param sig   3309-byte signature.
    function verify(
        bytes memory aHat,
        bytes memory tr,
        bytes memory pk,
        bytes memory message,
        bytes memory sig
    ) internal pure returns (bool) {
        if (
            pk.length != PK_BYTES || sig.length != SIG_BYTES
                || aHat.length != MATRIX_BYTES || tr.length != 64
        ) {
            return false;
        }

        // ---- parse signature: c~ || z || h ----
        bytes memory ctilde = new bytes(CTILDE);
        for (uint256 i = 0; i < CTILDE; i++) ctilde[i] = sig[i];

        uint256[256][5] memory zhat;
        for (uint256 i = 0; i < L; i++) {
            unpackBits(sig, CTILDE + i * 640, 20, zhat[i]);
            // z = GAMMA1 - raw, and the infinity-norm bound must hold.
            for (uint256 j = 0; j < 256; j++) {
                int256 v = int256(GAMMA1) - int256(zhat[i][j]);
                int256 av = v < 0 ? -v : v;
                if (av >= int256(GAMMA1 - BETA)) return false;
                zhat[i][j] = uint256((v % int256(Q) + int256(Q)) % int256(Q));
            }
            ntt(zhat[i]);
        }

        // ---- parse and validate the hint ----
        uint256[256][6] memory h;
        {
            uint256 base = CTILDE + L * 640;
            uint256 idx = 0;
            for (uint256 i = 0; i < K; i++) {
                uint256 end = uint8(sig[base + OMEGA + i]);
                if (end < idx || end > OMEGA) return false;
                uint256 first = idx;
                while (idx < end) {
                    if (idx > first && uint8(sig[base + idx - 1]) >= uint8(sig[base + idx])) {
                        return false;
                    }
                    h[i][uint8(sig[base + idx])] = 1;
                    unchecked { idx++; }
                }
            }
            for (uint256 i = idx; i < OMEGA; i++) {
                if (uint8(sig[base + i]) != 0) return false;
            }
            if (idx > OMEGA) return false;
        }

        // ---- mu = H(H(pk,64) || 0x00 || 0x00 || M, 64) ----
        bytes memory mu;
        {
            bytes memory pre = new bytes(64 + 2 + message.length);
            for (uint256 i = 0; i < 64; i++) pre[i] = tr[i];
            pre[64] = 0x00; // pure ML-DSA
            pre[65] = 0x00; // empty context
            for (uint256 i = 0; i < message.length; i++) pre[66 + i] = message[i];
            mu = Keccak.shake256(pre, 64);
        }

        // ---- c-hat ----
        uint256[256] memory chat;
        sampleInBall(ctilde, chat);
        ntt(chat);

        // ---- w1 = UseHint(h, NTT^-1(A z - c t1 2^d)), encoded 4 bits per coefficient ----
        bytes memory w1enc = new bytes(768);
        {
            uint256[256] memory acc;
            uint256[256] memory tmp;
            for (uint256 i = 0; i < K; i++) {
                for (uint256 n = 0; n < 256; n++) acc[n] = 0;

                for (uint256 j = 0; j < L; j++) {
                    _mulAcc(aHat, ((i * L) + j) * POLY_BYTES, zhat[j], acc);
                }

                // t1_i * 2^d, then subtract c-hat * that
                unpackBits(pk, 32 + i * 320, 10, tmp);
                _scale(tmp, 1 << D);
                ntt(tmp);
                _mulSub(chat, tmp, acc);

                intt(acc);

                for (uint256 n = 0; n < 256; n++) {
                    uint256 w1 = useHint(h[i][n], acc[n]);
                    uint256 bit = (i * 256 + n) * 4;
                    w1enc[bit >> 3] |= bytes1(uint8(w1 << (bit & 7)));
                }
            }
        }

        // ---- c~' == c~ ----
        bytes memory ct2;
        {
            bytes memory buf = new bytes(64 + 768);
            for (uint256 i = 0; i < 64; i++) buf[i] = mu[i];
            for (uint256 i = 0; i < 768; i++) buf[64 + i] = w1enc[i];
            ct2 = Keccak.shake256(buf, CTILDE);
        }
        for (uint256 i = 0; i < CTILDE; i++) {
            if (ct2[i] != ctilde[i]) return false;
        }
        return true;
    }

    /// @dev acc += A_poly * z, coefficientwise in the NTT domain. Assembly to avoid
    ///      7,680 bounds checks per verification.
    function _mulAcc(
        bytes memory aHat,
        uint256 poff,
        uint256[256] memory z,
        uint256[256] memory acc
    ) private pure {
        assembly ("memory-safe") {
            let ap := add(add(aHat, 32), poff)
            for { let n := 0 } lt(n, 256) { n := add(n, 1) } {
                let pn := add(acc, shl(5, n))
                mstore(
                    pn,
                    addmod(
                        mload(pn),
                        mulmod(shr(224, mload(add(ap, shl(2, n)))), mload(add(z, shl(5, n))), 8380417),
                        8380417
                    )
                )
            }
        }
    }

    /// @dev acc -= c * t, coefficientwise in the NTT domain.
    function _mulSub(uint256[256] memory c, uint256[256] memory t, uint256[256] memory acc)
        private
        pure
    {
        assembly ("memory-safe") {
            for { let n := 0 } lt(n, 256) { n := add(n, 1) } {
                let pn := add(acc, shl(5, n))
                let m := mulmod(mload(add(c, shl(5, n))), mload(add(t, shl(5, n))), 8380417)
                mstore(pn, addmod(mload(pn), sub(8380417, m), 8380417))
            }
        }
    }

    function _scale(uint256[256] memory a, uint256 f) private pure {
        assembly ("memory-safe") {
            for { let n := 0 } lt(n, 256) { n := add(n, 1) } {
                let pn := add(a, shl(5, n))
                mstore(pn, mulmod(mload(pn), f, 8380417))
            }
        }
    }

    /// @dev Big-endian 32-bit read at byte offset `off`.
    function _be32(bytes memory d, uint256 off) internal pure returns (uint256 v) {
        assembly ("memory-safe") {
            v := shr(224, mload(add(add(d, 32), off)))
        }
    }
}
