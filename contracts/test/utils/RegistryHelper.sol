// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {VLEIRegistry} from "../../src/VLEIRegistry.sol";

/// @notice Shared helpers: sign and submit verifier attestations against a VLEIRegistry.
abstract contract RegistryHelper is Test {
    VLEIRegistry internal registry;
    uint256 internal verifierPk = 0xA11CE;

    uint8 internal constant ECR = 1;
    uint8 internal constant OOR = 2;
    uint8 internal constant OFFICER = 3;

    function _sign(VLEIRegistry.Attestation memory att, uint256 pk) internal view returns (bytes memory) {
        bytes32 digest = registry.hashAttestation(att);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _att(address wallet, bytes32 lei, uint8 role) internal view returns (VLEIRegistry.Attestation memory) {
        return VLEIRegistry.Attestation({
            wallet: wallet,
            leiHash: lei,
            role: role,
            nonce: registry.nonces(wallet),
            expiresAt: uint64(block.timestamp + 7 days)
        });
    }

    function _register(address wallet, bytes32 lei, uint8 role) internal {
        VLEIRegistry.Attestation memory att = _att(wallet, lei, role);
        registry.register(att, _sign(att, verifierPk));
    }
}
