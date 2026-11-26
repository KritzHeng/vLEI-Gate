// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VLEIRegistry} from "../src/VLEIRegistry.sol";
import {RegistryHelper} from "./utils/RegistryHelper.sol";

contract VLEIRegistryTest is RegistryHelper {
    address admin = makeAddr("admin");
    address verifier;

    address issuer = makeAddr("issuerCEO");
    address investor = makeAddr("investorECR");
    address outsider = makeAddr("unverified");
    address oorNonOfficer = makeAddr("oorTreasurer");

    bytes32 issuerLei = keccak256("5493001KJTIIGC8Y1R12");
    bytes32 investorLei = keccak256("984500E1B2C3D4E5F617");

    function setUp() public {
        vm.warp(1_750_000_000);
        verifier = vm.addr(verifierPk);
        registry = new VLEIRegistry(admin, verifier);

        _register(issuer, issuerLei, 3);
        _register(investor, investorLei, 1);
        _register(oorNonOfficer, issuerLei, 2);
    }

    function test_registerAndActive() public view {
        assertTrue(registry.isActive(issuer));
        assertTrue(registry.canLaunch(issuer));
        assertFalse(registry.canLaunch(investor));
        assertFalse(registry.canLaunch(oorNonOfficer));
        assertFalse(registry.isActive(outsider));
        assertEq(registry.nonces(issuer), 1);
    }

    function test_rejectNonVerifierSignature() public {
        VLEIRegistry.Attestation memory att = _att(outsider, investorLei, 1);
        bytes memory sig = _sign(att, 0xBAD);
        vm.expectRevert(abi.encodeWithSelector(VLEIRegistry.InvalidSigner.selector, vm.addr(0xBAD)));
        registry.register(att, sig);
    }

    function test_rejectReplay() public {
        VLEIRegistry.Attestation memory att = _att(outsider, investorLei, 1);
        bytes memory sig = _sign(att, verifierPk);
        registry.register(att, sig);
        vm.expectRevert(VLEIRegistry.InvalidNonce.selector);
        registry.register(att, sig);
    }

    function test_rejectTamperedRole() public {
        VLEIRegistry.Attestation memory att = _att(outsider, investorLei, 1);
        bytes memory sig = _sign(att, verifierPk);
        att.role = 3; // try to escalate ECR -> OOR officer
        vm.expectPartialRevert(VLEIRegistry.InvalidSigner.selector);
        registry.register(att, sig);
    }

    function test_rejectCrossChainReplay() public {
        VLEIRegistry.Attestation memory att = _att(outsider, investorLei, 1);
        bytes memory sig = _sign(att, verifierPk);
        vm.chainId(56); // same attestation submitted on another chain
        vm.expectPartialRevert(VLEIRegistry.InvalidSigner.selector);
        registry.register(att, sig);
    }

    function test_expiry() public {
        vm.warp(block.timestamp + 7 days + 1);
        assertFalse(registry.isActive(issuer));
    }

    function test_ttlTooLong() public {
        VLEIRegistry.Attestation memory att = _att(outsider, investorLei, 1);
        att.expiresAt = uint64(block.timestamp + 31 days);
        bytes memory sig = _sign(att, verifierPk);
        vm.expectRevert(VLEIRegistry.TtlTooLong.selector);
        registry.register(att, sig);
    }

    function test_onlyAdminRevokes() public {
        vm.prank(verifier);
        vm.expectRevert();
        registry.revokeEntity(investorLei, "x");
        vm.prank(admin);
        registry.revokeEntity(investorLei, "TEL revocation");
        assertFalse(registry.isActive(investor));
    }

    function test_revokedEntityCannotReRegister() public {
        vm.prank(admin);
        registry.revokeEntity(investorLei, "TEL revocation");
        VLEIRegistry.Attestation memory att = _att(investor, investorLei, 1);
        bytes memory sig = _sign(att, verifierPk);
        vm.expectRevert(VLEIRegistry.EntityIsRevoked.selector);
        registry.register(att, sig);
    }

    function test_verifierRotation() public {
        vm.startPrank(admin);
        registry.revokeRole(registry.VERIFIER_ROLE(), verifier);
        vm.stopPrank();
        VLEIRegistry.Attestation memory att = _att(outsider, investorLei, 1);
        bytes memory sig = _sign(att, verifierPk);
        vm.expectPartialRevert(VLEIRegistry.InvalidSigner.selector);
        registry.register(att, sig);
    }


    function test_revokeWalletInvalidatesPendingAttestation() public {
        VLEIRegistry.Attestation memory pending = _att(investor, investorLei, 1); // stockpiled for next nonce
        bytes memory sig = _sign(pending, verifierPk);
        vm.prank(admin);
        registry.revokeWallet(investor, "OOR/ECR revoked");
        vm.expectRevert(VLEIRegistry.InvalidNonce.selector);
        registry.register(pending, sig);
        assertFalse(registry.isActive(investor));
    }

    function test_reRegisterAfterWalletRevocation() public {
        vm.prank(admin);
        registry.revokeWallet(investor, "rotated key");
        assertFalse(registry.isActive(investor));
        _register(investor, investorLei, 1); // fresh attestation on the bumped nonce
        assertTrue(registry.isActive(investor));
    }
}
