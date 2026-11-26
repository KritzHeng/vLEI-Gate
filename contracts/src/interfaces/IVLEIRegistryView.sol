// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Public getters of `VLEIRegistry` beyond `IVLEIRegistry`, used to tell a revocation apart from an expiry.
/// @dev Same shape as `VLEIRegistry.Registration` / `getRegistration`; declared separately so new contracts do not
///      depend on `VLEIMintLauncher.sol`.
interface IVLEIRegistryView {
    struct Registration {
        bytes32 leiHash;
        uint8 role;
        uint64 expiresAt;
        uint64 registeredAt;
        address verifier;
    }

    function getRegistration(address wallet) external view returns (Registration memory);
    function walletRevoked(address wallet) external view returns (bool);
    function entityRevoked(bytes32 leiHash) external view returns (bool);
}
