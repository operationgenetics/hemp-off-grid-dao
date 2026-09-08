// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "./MLDSA65.sol";
import "./Keccak.sol";
import "./IPQCVerifier.sol";

/**
 * @title MLDSA65Verifier
 * @notice On-chain ML-DSA-65 (FIPS 204) verification for one fixed public key.
 *
 * @dev ExpandA(rho) and tr = H(pk,64) depend only on the public key, so they are
 *      identical on every verification. Recomputing ExpandA costs ~28.5M gas, which
 *      does not fit in an Arbitrum block alongside the rest of the verify. They are
 *      therefore computed and PROVEN on-chain once, at commit time, and cached.
 *
 *      Caching is trustless, not trusted: `commitMatrixChunk` recomputes each of the
 *      30 polynomials with the same rejection sampler used by the reference and
 *      reverts unless the supplied bytes match exactly. Nobody, including the
 *      committer, can install a matrix that is not ExpandA(rho).
 *
 *      Once `seal()` is called the verifier is frozen forever: no key, no matrix and
 *      no parameter can change, so it is safe to register in a DAO that will itself
 *      become immutable.
 */
contract MLDSA65Verifier is IPQCVerifier {
    uint256 private constant POLYS = 30;          // K * L
    uint256 private constant CHUNKS = 3;
    uint256 private constant POLYS_PER_CHUNK = 10;
    uint256 private constant CHUNK_BYTES = POLYS_PER_CHUNK * 1024; // 10,240

    /// @notice The one public key this verifier is bound to.
    bytes public publicKey;
    bytes32 public immutable publicKeyHash;

    /// @notice H(pk, 64), recomputed and checked on-chain in commitTr().
    bytes public tr;

    /// @notice SSTORE2-style data contracts holding ExpandA(rho), 10 polynomials each.
    address[CHUNKS] public matrixChunk;

    /// @notice Only this address may run the commitment steps. It cannot install
    ///         anything unverified; it can only pay the gas to prove the cache.
    address public immutable committer;

    bool public trCommitted;
    bool public isSealed;

    error NotCommitter();
    error AlreadySealed();
    error NotSealed();
    error BadChunkIndex();
    error ChunkAlreadyCommitted();
    error BadChunkLength();
    error MatrixMismatch(uint256 polyIndex, uint256 coeffIndex);
    error TrMismatch();
    error TrNotCommitted();
    error ChunksIncomplete();
    error DeployFailed();

    event TrCommitted(bytes32 trHash);
    event MatrixChunkCommitted(uint256 indexed chunkIndex, address dataContract);
    event Sealed();

    modifier onlyCommitter() {
        if (msg.sender != committer) revert NotCommitter();
        if (isSealed) revert AlreadySealed();
        _;
    }

    constructor(bytes memory pk, address committer_) {
        require(pk.length == MLDSA65.PK_BYTES, "pk must be 1952 bytes");
        require(committer_ != address(0), "committer required");
        publicKey = pk;
        publicKeyHash = keccak256(pk);
        committer = committer_;
    }

    /*//////////////////////////////////////////////////////////////
                            ONE-TIME COMMITMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Compute tr = H(pk, 64) on-chain and store it. ~2M gas, paid once.
    function commitTr() external onlyCommitter {
        bytes memory computed = Keccak.shake256(publicKey, 64);
        tr = computed;
        trCommitted = true;
        emit TrCommitted(keccak256(computed));
    }

    /// @notice Prove and store 10 polynomials of ExpandA(rho).
    /// @dev Recomputes each polynomial with the FIPS 204 rejection sampler and reverts
    ///      on the first mismatched coefficient, so the stored matrix is exactly
    ///      ExpandA(rho) or the transaction fails. ~15M gas per chunk.
    function commitMatrixChunk(uint256 chunkIndex, bytes calldata polys) external onlyCommitter {
        if (chunkIndex >= CHUNKS) revert BadChunkIndex();
        if (matrixChunk[chunkIndex] != address(0)) revert ChunkAlreadyCommitted();
        if (polys.length != CHUNK_BYTES) revert BadChunkLength();

        bytes memory pk = publicKey;
        bytes memory seed = new bytes(34);
        for (uint256 i = 0; i < 32; i++) seed[i] = pk[i]; // rho

        bytes memory supplied = polys;
        uint256[256] memory expected;

        for (uint256 p = 0; p < POLYS_PER_CHUNK; p++) {
            uint256 polyIndex = chunkIndex * POLYS_PER_CHUNK + p;
            seed[32] = bytes1(uint8(polyIndex % MLDSA65.L)); // s (column)
            seed[33] = bytes1(uint8(polyIndex / MLDSA65.L)); // r (row)

            MLDSA65.rejNttPoly(seed, expected);

            uint256 base = p * 1024;
            for (uint256 n = 0; n < 256; n++) {
                if (MLDSA65._be32(supplied, base + n * 4) != expected[n]) {
                    revert MatrixMismatch(polyIndex, n);
                }
            }
        }

        matrixChunk[chunkIndex] = _write(supplied);
        emit MatrixChunkCommitted(chunkIndex, matrixChunk[chunkIndex]);
    }

    /// @notice Freeze the verifier permanently. Everything must already be proven.
    function seal() external onlyCommitter {
        if (!trCommitted) revert TrNotCommitted();
        for (uint256 i = 0; i < CHUNKS; i++) {
            if (matrixChunk[i] == address(0)) revert ChunksIncomplete();
        }
        isSealed = true;
        emit Sealed();
    }

    /*//////////////////////////////////////////////////////////////
                                 VERIFY
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IPQCVerifier
    /// @dev The digest is verified as a 32-byte message under pure ML-DSA with an
    ///      empty context, matching FIPS 204 ML-DSA.Verify.
    function verify(bytes calldata pk, bytes32 digest, bytes calldata signature)
        external
        view
        returns (bool)
    {
        if (!isSealed) return false;
        if (keccak256(pk) != publicKeyHash) return false;
        if (signature.length != MLDSA65.SIG_BYTES) return false;

        bytes memory message = abi.encodePacked(digest);
        return MLDSA65.verify(_matrix(), tr, publicKey, message, signature);
    }

    /// @notice The committed ExpandA(rho), reassembled from its data contracts.
    function expandedMatrix() external view returns (bytes memory) {
        return _matrix();
    }

    function _matrix() private view returns (bytes memory out) {
        out = new bytes(MLDSA65.MATRIX_BYTES);
        for (uint256 i = 0; i < CHUNKS; i++) {
            address ptr = matrixChunk[i];
            uint256 dest;
            assembly ("memory-safe") {
                dest := add(add(out, 32), mul(i, 10240))
                extcodecopy(ptr, dest, 1, 10240)
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                          SSTORE2 DATA CONTRACTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Store `data` as contract bytecode behind a leading STOP, so reads are a
    ///      single EXTCODECOPY (~3 gas per word) instead of ~320 cold SLOADs.
    function _write(bytes memory data) private returns (address ptr) {
        bytes memory creation = abi.encodePacked(
            hex"60_0B_59_81_38_03_80_92_59_39_F3", // deploy the trailing bytes as code
            hex"00",                                // STOP: the data contract is inert
            data
        );
        assembly ("memory-safe") {
            ptr := create(0, add(creation, 32), mload(creation))
        }
        if (ptr == address(0)) revert DeployFailed();
    }
}
