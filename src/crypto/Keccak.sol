// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title Keccak
 * @notice Keccak-f[1600] permutation and the SHAKE-128 / SHAKE-256 extendable-output
 *         functions from FIPS 202, with an incremental squeeze API.
 *
 * @dev The EVM's KECCAK256 opcode cannot be reused here. It is Keccak-256 with the
 *      original 0x01 domain padding, whereas SHAKE uses 0x1F, and SHAKE-128 runs at a
 *      168-byte rate rather than 136. ML-DSA needs both XOFs with arbitrary-length
 *      output, so the permutation is implemented from scratch.
 *
 *      Lanes are little-endian 64-bit words held one per 256-bit memory slot.
 */
library Keccak {
    uint256 internal constant MASK64 = 0xFFFFFFFFFFFFFFFF;

    uint256 internal constant RATE_128 = 168; // SHAKE-128
    uint256 internal constant RATE_256 = 136; // SHAKE-256

    /// @dev Sponge state plus squeeze cursor, so output can be drawn incrementally.
    struct XOF {
        uint256[25] st;
        uint256 rate; // bytes absorbed/squeezed per permutation
        uint256 pos;  // bytes already taken from the current output block
    }

    /*//////////////////////////////////////////////////////////////
                          KECCAK-f[1600] PERMUTATION
    //////////////////////////////////////////////////////////////*/

    /// @notice In-place Keccak-f[1600]: 24 rounds of theta, rho+pi, chi, iota.
    function f1600(uint256[25] memory a) internal pure {
        assembly ("memory-safe") {

            // Scratch: b = rho+pi output, cm/dm = theta temporaries, rc = round constants.
            // Scratch is transient: claim it, then hand it straight back. Leaking it
            // would grow memory ~1.9KB per call, and ExpandA calls this ~180 times,
            // where the quadratic expansion term dominates everything else.
            let fmp := mload(0x40)
            let b := fmp
            let cm := add(b, 800)
            let dm := add(cm, 160)
            let rc := add(dm, 160)
            mstore(0x40, add(rc, 768))

            mstore(add(rc, 0),   0x0000000000000001) mstore(add(rc, 32),  0x0000000000008082)
            mstore(add(rc, 64),  0x800000000000808a) mstore(add(rc, 96),  0x8000000080008000)
            mstore(add(rc, 128), 0x000000000000808b) mstore(add(rc, 160), 0x0000000080000001)
            mstore(add(rc, 192), 0x8000000080008081) mstore(add(rc, 224), 0x8000000000008009)
            mstore(add(rc, 256), 0x000000000000008a) mstore(add(rc, 288), 0x0000000000000088)
            mstore(add(rc, 320), 0x0000000080008009) mstore(add(rc, 352), 0x000000008000000a)
            mstore(add(rc, 384), 0x000000008000808b) mstore(add(rc, 416), 0x800000000000008b)
            mstore(add(rc, 448), 0x8000000000008089) mstore(add(rc, 480), 0x8000000000008003)
            mstore(add(rc, 512), 0x8000000000008002) mstore(add(rc, 544), 0x8000000000000080)
            mstore(add(rc, 576), 0x000000000000800a) mstore(add(rc, 608), 0x800000008000000a)
            mstore(add(rc, 640), 0x8000000080008081) mstore(add(rc, 672), 0x8000000000008080)
            mstore(add(rc, 704), 0x0000000080000001) mstore(add(rc, 736), 0x8000000080008008)

            for { let round := 0 } lt(round, 24) { round := add(round, 1) } {
                // theta: column parities -> scratch (kept off the stack so nothing spills)
                mstore(cm,xor(xor(xor(xor(mload(a),mload(add(a,160))),mload(add(a,320))),mload(add(a,480))),mload(add(a,640))))
                mstore(add(cm,32),xor(xor(xor(xor(mload(add(a,32)),mload(add(a,192))),mload(add(a,352))),mload(add(a,512))),mload(add(a,672))))
                mstore(add(cm,64),xor(xor(xor(xor(mload(add(a,64)),mload(add(a,224))),mload(add(a,384))),mload(add(a,544))),mload(add(a,704))))
                mstore(add(cm,96),xor(xor(xor(xor(mload(add(a,96)),mload(add(a,256))),mload(add(a,416))),mload(add(a,576))),mload(add(a,736))))
                mstore(add(cm,128),xor(xor(xor(xor(mload(add(a,128)),mload(add(a,288))),mload(add(a,448))),mload(add(a,608))),mload(add(a,768))))

                // theta: d[x] = c[x-1] ^ rotl(c[x+1],1) -> scratch
                mstore(dm,xor(mload(add(cm,128)),and(or(shl(1,mload(add(cm,32))),shr(63,mload(add(cm,32)))),0xFFFFFFFFFFFFFFFF)))
                mstore(add(dm,32),xor(mload(cm),and(or(shl(1,mload(add(cm,64))),shr(63,mload(add(cm,64)))),0xFFFFFFFFFFFFFFFF)))
                mstore(add(dm,64),xor(mload(add(cm,32)),and(or(shl(1,mload(add(cm,96))),shr(63,mload(add(cm,96)))),0xFFFFFFFFFFFFFFFF)))
                mstore(add(dm,96),xor(mload(add(cm,64)),and(or(shl(1,mload(add(cm,128))),shr(63,mload(add(cm,128)))),0xFFFFFFFFFFFFFFFF)))
                mstore(add(dm,128),xor(mload(add(cm,96)),and(or(shl(1,mload(cm)),shr(63,mload(cm))),0xFFFFFFFFFFFFFFFF)))

                // theta writeback fused with rho+pi, one lane at a time
                { let t := xor(mload(a),mload(dm)) mstore(b,t) }
                { let t := xor(mload(add(a,32)),mload(add(dm,32))) mstore(add(b,320),and(or(shl(1,t),shr(63,t)),0xFFFFFFFFFFFFFFFF)) }
                { let t := xor(mload(add(a,64)),mload(add(dm,64))) mstore(add(b,640),and(or(shl(62,t),shr(2,t)),0xFFFFFFFFFFFFFFFF)) }
                { let t := xor(mload(add(a,96)),mload(add(dm,96))) mstore(add(b,160),and(or(shl(28,t),shr(36,t)),0xFFFFFFFFFFFFFFFF)) }
                { let t := xor(mload(add(a,128)),mload(add(dm,128))) mstore(add(b,480),and(or(shl(27,t),shr(37,t)),0xFFFFFFFFFFFFFFFF)) }
                { let t := xor(mload(add(a,160)),mload(dm)) mstore(add(b,512),and(or(shl(36,t),shr(28,t)),0xFFFFFFFFFFFFFFFF)) }
                { let t := xor(mload(add(a,192)),mload(add(dm,32))) mstore(add(b,32),and(or(shl(44,t),shr(20,t)),0xFFFFFFFFFFFFFFFF)) }
                { let t := xor(mload(add(a,224)),mload(add(dm,64))) mstore(add(b,352),and(or(shl(6,t),shr(58,t)),0xFFFFFFFFFFFFFFFF)) }
                { let t := xor(mload(add(a,256)),mload(add(dm,96))) mstore(add(b,672),and(or(shl(55,t),shr(9,t)),0xFFFFFFFFFFFFFFFF)) }
                { let t := xor(mload(add(a,288)),mload(add(dm,128))) mstore(add(b,192),and(or(shl(20,t),shr(44,t)),0xFFFFFFFFFFFFFFFF)) }
                { let t := xor(mload(add(a,320)),mload(dm)) mstore(add(b,224),and(or(shl(3,t),shr(61,t)),0xFFFFFFFFFFFFFFFF)) }
                { let t := xor(mload(add(a,352)),mload(add(dm,32))) mstore(add(b,544),and(or(shl(10,t),shr(54,t)),0xFFFFFFFFFFFFFFFF)) }
                { let t := xor(mload(add(a,384)),mload(add(dm,64))) mstore(add(b,64),and(or(shl(43,t),shr(21,t)),0xFFFFFFFFFFFFFFFF)) }
                { let t := xor(mload(add(a,416)),mload(add(dm,96))) mstore(add(b,384),and(or(shl(25,t),shr(39,t)),0xFFFFFFFFFFFFFFFF)) }
                { let t := xor(mload(add(a,448)),mload(add(dm,128))) mstore(add(b,704),and(or(shl(39,t),shr(25,t)),0xFFFFFFFFFFFFFFFF)) }
                { let t := xor(mload(add(a,480)),mload(dm)) mstore(add(b,736),and(or(shl(41,t),shr(23,t)),0xFFFFFFFFFFFFFFFF)) }
                { let t := xor(mload(add(a,512)),mload(add(dm,32))) mstore(add(b,256),and(or(shl(45,t),shr(19,t)),0xFFFFFFFFFFFFFFFF)) }
                { let t := xor(mload(add(a,544)),mload(add(dm,64))) mstore(add(b,576),and(or(shl(15,t),shr(49,t)),0xFFFFFFFFFFFFFFFF)) }
                { let t := xor(mload(add(a,576)),mload(add(dm,96))) mstore(add(b,96),and(or(shl(21,t),shr(43,t)),0xFFFFFFFFFFFFFFFF)) }
                { let t := xor(mload(add(a,608)),mload(add(dm,128))) mstore(add(b,416),and(or(shl(8,t),shr(56,t)),0xFFFFFFFFFFFFFFFF)) }
                { let t := xor(mload(add(a,640)),mload(dm)) mstore(add(b,448),and(or(shl(18,t),shr(46,t)),0xFFFFFFFFFFFFFFFF)) }
                { let t := xor(mload(add(a,672)),mload(add(dm,32))) mstore(add(b,768),and(or(shl(2,t),shr(62,t)),0xFFFFFFFFFFFFFFFF)) }
                { let t := xor(mload(add(a,704)),mload(add(dm,64))) mstore(add(b,288),and(or(shl(61,t),shr(3,t)),0xFFFFFFFFFFFFFFFF)) }
                { let t := xor(mload(add(a,736)),mload(add(dm,96))) mstore(add(b,608),and(or(shl(56,t),shr(8,t)),0xFFFFFFFFFFFFFFFF)) }
                { let t := xor(mload(add(a,768)),mload(add(dm,128))) mstore(add(b,128),and(or(shl(14,t),shr(50,t)),0xFFFFFFFFFFFFFFFF)) }

                // chi
                mstore(a,xor(mload(b),and(and(not(mload(add(b,32))),0xFFFFFFFFFFFFFFFF),mload(add(b,64)))))
                mstore(add(a,32),xor(mload(add(b,32)),and(and(not(mload(add(b,64))),0xFFFFFFFFFFFFFFFF),mload(add(b,96)))))
                mstore(add(a,64),xor(mload(add(b,64)),and(and(not(mload(add(b,96))),0xFFFFFFFFFFFFFFFF),mload(add(b,128)))))
                mstore(add(a,96),xor(mload(add(b,96)),and(and(not(mload(add(b,128))),0xFFFFFFFFFFFFFFFF),mload(b))))
                mstore(add(a,128),xor(mload(add(b,128)),and(and(not(mload(b)),0xFFFFFFFFFFFFFFFF),mload(add(b,32)))))
                mstore(add(a,160),xor(mload(add(b,160)),and(and(not(mload(add(b,192))),0xFFFFFFFFFFFFFFFF),mload(add(b,224)))))
                mstore(add(a,192),xor(mload(add(b,192)),and(and(not(mload(add(b,224))),0xFFFFFFFFFFFFFFFF),mload(add(b,256)))))
                mstore(add(a,224),xor(mload(add(b,224)),and(and(not(mload(add(b,256))),0xFFFFFFFFFFFFFFFF),mload(add(b,288)))))
                mstore(add(a,256),xor(mload(add(b,256)),and(and(not(mload(add(b,288))),0xFFFFFFFFFFFFFFFF),mload(add(b,160)))))
                mstore(add(a,288),xor(mload(add(b,288)),and(and(not(mload(add(b,160))),0xFFFFFFFFFFFFFFFF),mload(add(b,192)))))
                mstore(add(a,320),xor(mload(add(b,320)),and(and(not(mload(add(b,352))),0xFFFFFFFFFFFFFFFF),mload(add(b,384)))))
                mstore(add(a,352),xor(mload(add(b,352)),and(and(not(mload(add(b,384))),0xFFFFFFFFFFFFFFFF),mload(add(b,416)))))
                mstore(add(a,384),xor(mload(add(b,384)),and(and(not(mload(add(b,416))),0xFFFFFFFFFFFFFFFF),mload(add(b,448)))))
                mstore(add(a,416),xor(mload(add(b,416)),and(and(not(mload(add(b,448))),0xFFFFFFFFFFFFFFFF),mload(add(b,320)))))
                mstore(add(a,448),xor(mload(add(b,448)),and(and(not(mload(add(b,320))),0xFFFFFFFFFFFFFFFF),mload(add(b,352)))))
                mstore(add(a,480),xor(mload(add(b,480)),and(and(not(mload(add(b,512))),0xFFFFFFFFFFFFFFFF),mload(add(b,544)))))
                mstore(add(a,512),xor(mload(add(b,512)),and(and(not(mload(add(b,544))),0xFFFFFFFFFFFFFFFF),mload(add(b,576)))))
                mstore(add(a,544),xor(mload(add(b,544)),and(and(not(mload(add(b,576))),0xFFFFFFFFFFFFFFFF),mload(add(b,608)))))
                mstore(add(a,576),xor(mload(add(b,576)),and(and(not(mload(add(b,608))),0xFFFFFFFFFFFFFFFF),mload(add(b,480)))))
                mstore(add(a,608),xor(mload(add(b,608)),and(and(not(mload(add(b,480))),0xFFFFFFFFFFFFFFFF),mload(add(b,512)))))
                mstore(add(a,640),xor(mload(add(b,640)),and(and(not(mload(add(b,672))),0xFFFFFFFFFFFFFFFF),mload(add(b,704)))))
                mstore(add(a,672),xor(mload(add(b,672)),and(and(not(mload(add(b,704))),0xFFFFFFFFFFFFFFFF),mload(add(b,736)))))
                mstore(add(a,704),xor(mload(add(b,704)),and(and(not(mload(add(b,736))),0xFFFFFFFFFFFFFFFF),mload(add(b,768)))))
                mstore(add(a,736),xor(mload(add(b,736)),and(and(not(mload(add(b,768))),0xFFFFFFFFFFFFFFFF),mload(add(b,640)))))
                mstore(add(a,768),xor(mload(add(b,768)),and(and(not(mload(add(b,640))),0xFFFFFFFFFFFFFFFF),mload(add(b,672)))))

                // iota
                mstore(a,xor(mload(a),mload(add(rc,mul(round,32)))))
            }

            mstore(0x40, fmp)
        }
    }

    /*//////////////////////////////////////////////////////////////
                                  SHAKE
    //////////////////////////////////////////////////////////////*/

    /// @notice Absorb `data` in full and apply the SHAKE 0x1F pad, leaving the sponge
    ///         ready to squeeze. One-shot absorb: all input must be supplied here.
    function absorb(XOF memory x, bytes memory data) internal pure {
        uint256 rate = x.rate;
        uint256 len = data.length;
        uint256 off = 0;

        while (len - off >= rate) {
            _xorBlock(x.st, data, off, rate);
            f1600(x.st);
            off += rate;
        }

        uint256 rem = len - off;
        _xorBlock(x.st, data, off, rem);
        // Domain separator 0x1F at the first pad byte, 0x80 at the last rate byte.
        _xorByte(x.st, rem, 0x1F);
        _xorByte(x.st, rate - 1, 0x80);
        f1600(x.st);

        x.pos = 0;
    }

    /// @notice Draw `outLen` bytes, continuing from wherever the last call stopped.
    function squeeze(XOF memory x, uint256 outLen) internal pure returns (bytes memory out) {
        out = new bytes(outLen);
        uint256 rate = x.rate;
        uint256 pos = x.pos;

        for (uint256 i = 0; i < outLen; i++) {
            if (pos == rate) {
                f1600(x.st);
                pos = 0;
            }
            out[i] = bytes1(_lane(x.st, pos));
            unchecked { pos++; }
        }
        x.pos = pos;
    }

    function shake128(bytes memory data, uint256 outLen) internal pure returns (bytes memory) {
        XOF memory x;
        x.rate = RATE_128;
        absorb(x, data);
        return squeeze(x, outLen);
    }

    function shake256(bytes memory data, uint256 outLen) internal pure returns (bytes memory) {
        XOF memory x;
        x.rate = RATE_256;
        absorb(x, data);
        return squeeze(x, outLen);
    }

    function newXof(uint256 rate) internal pure returns (XOF memory x) {
        x.rate = rate;
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNALS
    //////////////////////////////////////////////////////////////*/

    /// @dev Byte `i` of the state, in the little-endian lane layout.
    function _lane(uint256[25] memory st, uint256 i) private pure returns (uint8) {
        unchecked {
            return uint8((st[i / 8] >> (8 * (i % 8))) & 0xFF);
        }
    }

    function _xorByte(uint256[25] memory st, uint256 i, uint256 v) private pure {
        unchecked {
            st[i / 8] ^= v << (8 * (i % 8));
        }
    }

    /// @dev XOR `n` bytes of `data` starting at `off` into the first `n` state bytes.
    function _xorBlock(uint256[25] memory st, bytes memory data, uint256 off, uint256 n)
        private
        pure
    {
        unchecked {
            for (uint256 i = 0; i < n; i++) {
                st[i / 8] ^= uint256(uint8(data[off + i])) << (8 * (i % 8));
            }
        }
    }
}
