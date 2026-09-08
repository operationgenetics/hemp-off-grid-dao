// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "../src/crypto/MLDSA65.sol";

/// @dev Every vector here was produced by tools/mldsa_ref.py, which is itself
///      cross-checked against the dilithium-py reference on real signatures.
contract MLDSA65Test is Test {
    function _poly(string memory f) internal view returns (uint256[256] memory p) {
        bytes memory b = vm.readFileBinary(f);
        require(b.length == 1024, "bad poly vector");
        for (uint256 i = 0; i < 256; i++) p[i] = MLDSA65._be32(b, i * 4);
    }

    function test_NttMatchesReference() public view {
        uint256[256] memory a = _poly("test/vectors/ntt_in.bin");
        uint256[256] memory want = _poly("test/vectors/ntt_out.bin");
        MLDSA65.ntt(a);
        for (uint256 i = 0; i < 256; i++) assertEq(a[i], want[i], "ntt coefficient mismatch");
    }

    function test_InverseNttRoundTrips() public view {
        uint256[256] memory a = _poly("test/vectors/ntt_in.bin");
        uint256[256] memory orig = _poly("test/vectors/ntt_in.bin");
        MLDSA65.ntt(a);
        MLDSA65.intt(a);
        for (uint256 i = 0; i < 256; i++) assertEq(a[i], orig[i], "intt(ntt(x)) != x");
    }

    function test_SampleInBallMatchesReference() public view {
        bytes memory ct = new bytes(48);
        for (uint256 i = 0; i < 48; i++) ct[i] = bytes1(uint8(i));
        uint256[256] memory c;
        MLDSA65.sampleInBall(ct, c);

        uint256[256] memory want = _poly("test/vectors/sib_out.bin");
        uint256 nz;
        for (uint256 i = 0; i < 256; i++) {
            assertEq(c[i], want[i], "sampleInBall coefficient mismatch");
            if (c[i] != 0) nz++;
        }
        assertEq(nz, 49, "must have exactly TAU nonzero coefficients");
    }

    function test_RejNttPolyMatchesReference() public view {
        bytes memory rho = vm.readFileBinary("test/vectors/rho.bin");
        bytes memory seed = new bytes(34);
        for (uint256 i = 0; i < 32; i++) seed[i] = rho[i];
        seed[32] = 0x00; // s
        seed[33] = 0x00; // r

        uint256[256] memory got;
        MLDSA65.rejNttPoly(seed, got);
        uint256[256] memory want = _poly("test/vectors/rej_out.bin");
        for (uint256 i = 0; i < 256; i++) assertEq(got[i], want[i], "ExpandA coefficient mismatch");
    }

    /// @notice The layer that was silently wrong: bit-level unpacking of t1 (10-bit)
    ///         and z (20-bit). Tested directly rather than only through verify().
    function test_UnpackBitsMatchesReference() public view {
        bytes memory pk = vm.readFileBinary("test/vectors/pk.bin");
        bytes memory tr = vm.readFileBinary("test/vectors/tr.bin");
        uint256[256] memory got;
        MLDSA65.unpackBits(pk, 32, 10, got);
        uint256[256] memory want = _poly("test/vectors/t1_0.bin");
        for (uint256 i = 0; i < 256; i++) assertEq(got[i], want[i], "t1 10-bit unpack mismatch");

        bytes memory sig = vm.readFileBinary("test/vectors/sig.bin");
        MLDSA65.unpackBits(sig, 48, 20, got);
        want = _poly("test/vectors/z0_raw.bin");
        for (uint256 i = 0; i < 256; i++) assertEq(got[i], want[i], "z 20-bit unpack mismatch");
    }

    function test_UseHintKnownAnswers() public pure {
        (uint256 r1, int256 r0) = MLDSA65.decompose(5000000);
        assertEq(r1, 10);
        assertEq(r0, -237760);
        assertEq(MLDSA65.useHint(1, 5000000), 9);
        assertEq(MLDSA65.useHint(0, 5000000), 10);
    }

    function test_VerifyAcceptsARealSignature() public view {
        bytes memory aHat = vm.readFileBinary("test/vectors/ahat.bin");
        bytes memory pk = vm.readFileBinary("test/vectors/pk.bin");
        bytes memory tr = vm.readFileBinary("test/vectors/tr.bin");
        bytes memory msg_ = vm.readFileBinary("test/vectors/msg.bin");
        bytes memory sig = vm.readFileBinary("test/vectors/sig.bin");
        assertTrue(MLDSA65.verify(aHat, tr, pk, msg_, sig), "must accept a valid ML-DSA-65 signature");
    }

    function test_VerifyRejectsATamperedSignature() public view {
        bytes memory aHat = vm.readFileBinary("test/vectors/ahat.bin");
        bytes memory pk = vm.readFileBinary("test/vectors/pk.bin");
        bytes memory tr = vm.readFileBinary("test/vectors/tr.bin");
        bytes memory msg_ = vm.readFileBinary("test/vectors/msg.bin");
        bytes memory bad = vm.readFileBinary("test/vectors/sig_bad.bin");
        assertFalse(MLDSA65.verify(aHat, tr, pk, msg_, bad), "must reject a tampered signature");
    }

    function test_VerifyRejectsAWrongMessage() public view {
        bytes memory aHat = vm.readFileBinary("test/vectors/ahat.bin");
        bytes memory pk = vm.readFileBinary("test/vectors/pk.bin");
        bytes memory tr = vm.readFileBinary("test/vectors/tr.bin");
        bytes memory sig = vm.readFileBinary("test/vectors/sig.bin");
        assertFalse(MLDSA65.verify(aHat, tr, pk, "not the signed message", sig), "must reject a wrong message");
    }

    function test_GasVerify() public view {
        bytes memory aHat = vm.readFileBinary("test/vectors/ahat.bin");
        bytes memory pk = vm.readFileBinary("test/vectors/pk.bin");
        bytes memory tr = vm.readFileBinary("test/vectors/tr.bin");
        bytes memory msg_ = vm.readFileBinary("test/vectors/msg.bin");
        bytes memory sig = vm.readFileBinary("test/vectors/sig.bin");
        uint256 g = gasleft();
        MLDSA65.verify(aHat, tr, pk, msg_, sig);
        console.log("ML-DSA-65 verify gas:", g - gasleft());
    }
}
