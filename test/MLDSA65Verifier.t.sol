// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "../src/crypto/MLDSA65Verifier.sol";

contract MLDSA65VerifierTest is Test {
    MLDSA65Verifier v;
    address constant COMMITTER = 0xaF570ce3b32D765b1236635B0f541a7487A1fB8e;

    bytes pk;
    bytes sig;
    bytes sigBad;
    bytes ahat;
    bytes32 digest;

    /// @dev Arbitrum One's block gas limit. Every commitment step must fit under it.
    uint256 constant ARBITRUM_BLOCK_GAS_LIMIT = 32_000_000;

    function setUp() public {
        pk = vm.readFileBinary("test/vectors/pk.bin");
        ahat = vm.readFileBinary("test/vectors/ahat.bin");
        v = new MLDSA65Verifier(pk, COMMITTER);
    }

    function _chunk(uint256 i) internal view returns (bytes memory c) {
        c = new bytes(10240);
        for (uint256 j = 0; j < 10240; j++) c[j] = ahat[i * 10240 + j];
    }

    function _commitAll() internal {
        vm.startPrank(COMMITTER);
        v.commitTr();
        for (uint256 i = 0; i < 3; i++) v.commitMatrixChunk(i, _chunk(i));
        v.seal();
        vm.stopPrank();
    }

    function test_CommitmentStepsFitInAnArbitrumBlock() public {
        vm.startPrank(COMMITTER);

        uint256 g = gasleft();
        v.commitTr();
        uint256 trGas = g - gasleft();
        console.log("commitTr gas:", trGas);
        assertLt(trGas, ARBITRUM_BLOCK_GAS_LIMIT, "commitTr must fit in a block");

        for (uint256 i = 0; i < 3; i++) {
            g = gasleft();
            v.commitMatrixChunk(i, _chunk(i));
            uint256 cg = g - gasleft();
            console.log("commitMatrixChunk gas:", cg);
            assertLt(cg, ARBITRUM_BLOCK_GAS_LIMIT, "chunk commit must fit in a block");
        }
        v.seal();
        vm.stopPrank();
        assertTrue(v.isSealed());
    }

    /// @notice The whole point of the cache being trustless: a matrix that is not
    ///         ExpandA(rho) cannot be installed, even by the committer.
    function test_CannotCommitAForgedMatrix() public {
        bytes memory forged = _chunk(0);
        forged[500] = bytes1(uint8(forged[500]) ^ 0x01);

        vm.prank(COMMITTER);
        vm.expectRevert();
        v.commitMatrixChunk(0, forged);
    }

    function test_OnlyCommitterCanCommit() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(MLDSA65Verifier.NotCommitter.selector);
        v.commitTr();
    }

    function test_CommittedMatrixEqualsExpandA() public {
        _commitAll();
        assertEq(v.expandedMatrix(), ahat, "cached matrix must equal ExpandA(rho)");
    }

    function test_VerifyAcceptsRealSignatureThroughTheInterface() public {
        _commitAll();
        sig = vm.readFileBinary("test/vectors/sig.bin");
        bytes memory m = vm.readFileBinary("test/vectors/msg.bin");
        digest = bytes32(m);

        uint256 g = gasleft();
        bool ok = v.verify(pk, digest, sig);
        console.log("IPQCVerifier.verify gas:", g - gasleft());
        assertTrue(ok, "must accept a valid ML-DSA-65 signature");
    }

    function test_VerifyRejectsTamperedSignature() public {
        _commitAll();
        sigBad = vm.readFileBinary("test/vectors/sig_bad.bin");
        bytes memory m = vm.readFileBinary("test/vectors/msg.bin");
        assertFalse(v.verify(pk, bytes32(m), sigBad), "must reject a tampered signature");
    }

    function test_VerifyRejectsWrongDigest() public {
        _commitAll();
        sig = vm.readFileBinary("test/vectors/sig.bin");
        assertFalse(v.verify(pk, keccak256("wrong"), sig), "must reject a wrong digest");
    }

    function test_VerifyRejectsAForeignPublicKey() public {
        _commitAll();
        sig = vm.readFileBinary("test/vectors/sig.bin");
        bytes memory m = vm.readFileBinary("test/vectors/msg.bin");
        bytes memory other = vm.readFileBinary("test/vectors/pk.bin");
        other[0] = bytes1(uint8(other[0]) ^ 0x01);
        assertFalse(v.verify(other, bytes32(m), sig), "must reject a key it is not bound to");
    }

    function test_VerifyReturnsFalseBeforeSealing() public {
        sig = vm.readFileBinary("test/vectors/sig.bin");
        bytes memory m = vm.readFileBinary("test/vectors/msg.bin");
        assertFalse(v.verify(pk, bytes32(m), sig), "unsealed verifier must not validate");
    }

    function test_SealIsPermanent() public {
        _commitAll();
        vm.prank(COMMITTER);
        vm.expectRevert(MLDSA65Verifier.AlreadySealed.selector);
        v.commitTr();
    }
}
