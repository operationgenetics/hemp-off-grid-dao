// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "../src/crypto/Keccak.sol";

contract KeccakTest is Test {
    using Keccak for Keccak.XOF;

    function _range(uint256 n) internal pure returns (bytes memory b) {
        b = new bytes(n);
        for (uint256 i = 0; i < n; i++) b[i] = bytes1(uint8(i));
    }

    function test_Shake128KnownAnswers() public pure {
        assertEq(
            Keccak.shake128("", 32),
            hex"7f9c2ba4e88f827d616045507605853ed73b8093f6efbc88eb1a6eacfa66ef26"
        );
        assertEq(
            Keccak.shake128("abc", 32),
            hex"5881092dd818bf5cf8a3ddb793fbcba74097d5c526a6d35f97b83351940f2cc8"
        );
        assertEq(
            Keccak.shake128(_range(200), 32),
            hex"0c4234ca1e31801ae606f8b8d8e0665c66f42a21d601c2681858a92c79ad5d69"
        );
    }

    function test_Shake256KnownAnswers() public pure {
        assertEq(
            Keccak.shake256("", 32),
            hex"46b9dd2b0ba88d13233b3feb743eeb243fcd52ea62b81b82b50c27646ed5762f"
        );
        assertEq(
            Keccak.shake256("abc", 32),
            hex"483366601360a8771c6863080cc4114d8db44530f8f1e1ee4f94ea37e78b5739"
        );
        assertEq(
            Keccak.shake256(_range(200), 32),
            hex"4ee1ca03272b05d3bfb1e1c79a967f823b9fc5e4bb3987b1ba9e9cb5afb07a5e"
        );
    }

    /// @notice Multi-block absorb (200 bytes > both rates) and multi-block squeeze.
    function test_LongSqueezeSpansManyBlocks() public pure {
        bytes memory got = Keccak.shake128(_range(200), 400);
        assertEq(got.length, 400);
        // Prefix must agree with the single-block answer.
        for (uint256 i = 0; i < 32; i++) {
            assertEq(uint8(got[i]), uint8(bytes32(hex"0c4234ca1e31801ae606f8b8d8e0665c66f42a21d601c2681858a92c79ad5d69")[i]));
        }
    }

    /// @notice Incremental squeezing must equal one big squeeze — required by ExpandA,
    ///         which draws 3 bytes at a time until it has enough accepted samples.
    function test_IncrementalSqueezeMatchesOneShot() public pure {
        bytes memory oneShot = Keccak.shake128(_range(64), 500);

        Keccak.XOF memory x = Keccak.newXof(Keccak.RATE_128);
        Keccak.absorb(x, _range(64));

        bytes memory acc = new bytes(500);
        uint256 o = 0;
        while (o < 500) {
            uint256 n = (o % 7) + 1;
            if (o + n > 500) n = 500 - o;
            bytes memory chunk = Keccak.squeeze(x, n);
            for (uint256 i = 0; i < n; i++) acc[o + i] = chunk[i];
            o += n;
        }
        assertEq(acc, oneShot, "incremental squeeze must match one-shot");
    }

    function test_GasF1600() public {
        uint256[25] memory st;
        uint256 g = gasleft();
        Keccak.f1600(st);
        uint256 used = g - gasleft();
        console.log("Keccak-f1600 gas:", used);
        assertLt(used, 200_000);
    }

    /// @notice Amortised cost is what matters: ExpandA runs ~180 permutations in one
    ///         call, so any per-call memory leak shows up here as quadratic growth.
    function test_GasF1600Amortised() public {
        uint256[25] memory st;
        uint256 g = gasleft();
        for (uint256 i = 0; i < 100; i++) Keccak.f1600(st);
        uint256 used = g - gasleft();
        console.log("Keccak-f1600 x100 total gas:", used);
        console.log("Keccak-f1600 amortised gas :", used / 100);
    }

    function test_GasShake128Squeeze1000() public {
        uint256 g = gasleft();
        Keccak.shake128(_range(34), 1000);
        console.log("shake128 34->1000 bytes gas:", g - gasleft());
    }
}
