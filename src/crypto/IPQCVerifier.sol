// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title IPQCVerifier
 * @notice Post-quantum signature verifier registered with HempOffGridDAO.
 * @dev Implemented by MLDSA65Verifier for ML-DSA-65 (FIPS 204). Kept as its own
 *      interface so the DAO can be sealed against any conforming verifier.
 */
interface IPQCVerifier {
    /// @param publicKey The PQC public key the signature must verify under.
    /// @param digest    The 32-byte authorisation digest that was signed.
    /// @param signature The post-quantum signature.
    /// @return True only if the signature is valid for that key and digest.
    function verify(bytes calldata publicKey, bytes32 digest, bytes calldata signature)
        external
        view
        returns (bool);
}
