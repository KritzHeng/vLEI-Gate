// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LibClone} from "solady/utils/LibClone.sol";
import {VLEILauncherTest} from "./VLEILauncher.t.sol";
import {VLEIRegistry} from "../src/VLEIRegistry.sol";
import {VLEILauncherFactory} from "../src/VLEILauncherFactory.sol";
import {VLEIMintLauncher, VLEIMintConfig} from "../src/VLEIMintLauncher.sol";

/// @notice Regression tests for the review findings (PoCs ported from the reviewer's test/PoC.t.sol).
contract VLEILauncherReviewTest is VLEILauncherTest {
    function _createLong(uint256 dur) internal returns (VLEIMintLauncher l) {
        VLEIMintConfig memory c = _config(keccak256("long"));
        c.saleDuration = dur;
        uint256 fee = portal.SALT_LOCK_FEE();
        vm.prank(alice);
        l = VLEIMintLauncher(payable(portal.newLauncher{value: fee}(address(factory), abi.encode(c))));
    }

    /// Re-register alice with a 30-day TTL (revokeWallet bumps her nonce first).
    function _refreshAlice30d() internal {
        vm.prank(admin);
        registry.revokeWallet(alice, "refresh");
        VLEIRegistry.Attestation memory a = _att(alice, issuerLei, OFFICER);
        a.expiresAt = uint64(block.timestamp + 30 days);
        registry.register(a, _sign(a, verifierPk));
    }

    // ── #1 launch can never be stuck ────────────────────────────────────────

    function test_saleDurationCappedAt30Days() public {
        uint256 fee = portal.SALT_LOCK_FEE();
        VLEIMintConfig memory c = _config(keccak256("too-long"));
        c.saleDuration = 30 days + 1;
        vm.prank(alice);
        vm.expectRevert(VLEIMintLauncher.InvalidConfig.selector);
        portal.newLauncher{value: fee}(address(factory), abi.encode(c));

        c.saleDuration = 30 days;
        vm.prank(alice);
        portal.newLauncher{value: fee}(address(factory), abi.encode(c));
    }

    function test_targetBelowMinimumUsdRejectedAtCreation() public {
        assertEq(factory.minTargetUsd(), 1_600e18);
        uint256 fee = portal.SALT_LOCK_FEE();
        VLEIMintConfig memory c = _config(keccak256("tiny"));
        c.targetRaise = 2 ether; // $1,200 at $600
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(VLEILauncherFactory.TargetBelowMinimum.selector, 1_200e18, 1_600e18));
        portal.newLauncher{value: fee}(address(factory), abi.encode(c));

        vm.prank(alice);
        vm.expectRevert();
        factory.setMinTargetUsd(0);
        vm.prank(admin);
        factory.setMinTargetUsd(1_000e18);
        vm.prank(alice);
        portal.newLauncher{value: fee}(address(factory), abi.encode(c));
    }

    function test_stalePriceRejectedAtCreation() public {
        vm.warp(block.timestamp + 2 hours);
        uint256 fee = portal.SALT_LOCK_FEE();
        vm.prank(alice);
        vm.expectRevert(VLEILauncherFactory.StalePrice.selector);
        portal.newLauncher{value: fee}(address(factory), abi.encode(_config(keccak256("stale"))));
    }

    function test_portalRejectsLaunch_refundsOpenForEveryone() public {
        VLEIMintLauncher l = _launcher();
        portal.setMinPoolQuote(20 ether); // the Portal's floor rises above this sale's target
        _contribute(l, bob1, 4 ether);

        uint256 carolBefore = carol.balance;
        vm.expectEmit(address(l));
        emit VLEIMintLauncher.LaunchFailed(abi.encodeWithSignature("BelowLiquidityFloor(uint256,uint256)", 10 ether, 20 ether));
        vm.prank(carol);
        l.contribute{value: 7 ether}(); // 6 accepted, 1 returned

        assertFalse(l.launched());
        assertTrue(l.launchFailed());
        assertEq(l.status(), 2, "a rejected launch reports Failed");
        assertEq(l.raised(), 10 ether);
        assertEq(address(l).balance, 10 ether, "the Portal returned the raise");
        assertEq(carolBefore - carol.balance, 6 ether, "excess returned even when the launch failed");

        vm.prank(bob2);
        vm.expectRevert(VLEIMintLauncher.SaleClosed.selector);
        l.contribute{value: 1 ether}();
        vm.expectRevert(VLEIMintLauncher.SaleClosed.selector);
        l.cancelIfCreatorRevoked();

        // Everyone, including the contributor whose call triggered the launch, refunds immediately.
        vm.prank(bob1);
        l.refund();
        vm.prank(carol);
        l.refund();
        assertEq(carol.balance, carolBefore);
        assertEq(bob1.balance, 100 ether);
        assertEq(address(l).balance, 0);
    }

    function test_lowGasCannotForceALaunchFailure() public {
        VLEIMintLauncher l = _launcher();
        _contribute(l, bob1, 4 ether);
        vm.prank(carol);
        vm.expectRevert();
        l.contribute{value: 6 ether, gas: 3_000_000}();
        assertFalse(l.launchFailed());
        assertEq(l.raised(), 4 ether);

        _contribute(l, carol, 6 ether);
        assertTrue(l.launched());
    }

    // ── #2 / #3 creator checks ──────────────────────────────────────────────

    /// PoC: anyone cancelled the instant the creator's attestation lapsed.
    function test_expiryDoesNotAllowImmediateCancel() public {
        VLEIMintLauncher l = _createLong(20 days);
        _contribute(l, bob1, 3 ether);
        _contribute(l, carol, 3 ether);

        vm.warp(block.timestamp + 7 days); // alice's attestation lapses
        feed.setAnswer(600e8);
        assertFalse(l.creatorActive());
        vm.prank(outsider);
        vm.expectRevert(VLEIMintLauncher.IssuerStillActive.selector);
        l.cancelIfCreatorRevoked();

        // Contributions pause while the creator is lapsed ...
        _register(bob2, leiB, OOR); // bob2 lapsed too; keep the contributor side valid
        vm.prank(bob2);
        vm.expectRevert(VLEIMintLauncher.IssuerNotActive.selector);
        l.contribute{value: 1 ether}();

        // ... and resume once she renews.
        _register(alice, issuerLei, OFFICER);
        assertTrue(l.creatorActive());
        _contribute(l, bob2, 1 ether);
        assertEq(l.status(), 0);
    }

    function test_longExpiryAllowsCancelAfterGrace() public {
        VLEIMintLauncher l = _createLong(20 days);
        _contribute(l, bob1, 3 ether);
        vm.warp(block.timestamp + 7 days + 7 days - 1);
        vm.expectRevert(VLEIMintLauncher.IssuerStillActive.selector);
        l.cancelIfCreatorRevoked();
        vm.warp(block.timestamp + 1);
        vm.prank(outsider);
        l.cancelIfCreatorRevoked();
        vm.prank(bob1);
        l.refund();
        assertEq(bob1.balance, 100 ether);
    }

    /// PoC: a creator downgraded to ECR of another entity kept an un-cancellable sale that still launched.
    function test_creatorDowngradeStopsAndCancelsTheSale() public {
        VLEIMintLauncher l = _launcher();
        _contribute(l, bob1, 3 ether);
        _register(alice, keccak256("OTHER-LEI"), ECR);
        assertFalse(l.creatorActive());
        vm.prank(carol);
        vm.expectRevert(VLEIMintLauncher.IssuerNotActive.selector);
        l.contribute{value: 6 ether}();
        l.cancelIfCreatorRevoked();
        assertEq(l.status(), 3);
    }

    function test_creatorMovedToAnotherEntityAsOfficer() public {
        VLEIMintLauncher l = _launcher();
        assertEq(l.creatorLei(), issuerLei);
        _register(alice, keccak256("OTHER-LEI"), OFFICER); // still an officer, but of a different entity
        assertTrue(registry.canLaunch(alice));
        assertFalse(l.creatorActive());
        l.cancelIfCreatorRevoked();
        assertTrue(l.cancelled());
    }

    function test_creatorEntityRevokedAllowsCancel() public {
        VLEIMintLauncher l = _launcher();
        vm.prank(admin);
        registry.revokeEntity(issuerLei, "TEL");
        l.cancelIfCreatorRevoked();
        assertTrue(l.cancelled());
    }

    // ── #5 / #6 contributor withdrawals ─────────────────────────────────────

    /// PoC: a contributor exited a live sale just by letting the attestation lapse.
    function test_withdrawRequiresRealRevocation() public {
        VLEIMintLauncher l = _createLong(20 days);
        _refreshAlice30d();
        _contribute(l, bob1, 5 ether);
        _contribute(l, carol, 4 ether);
        vm.warp(block.timestamp + 7 days); // bob1 simply expires
        feed.setAnswer(600e8);
        vm.prank(bob1);
        vm.expectRevert(VLEIMintLauncher.StillVerified.selector);
        l.withdrawContribution();
        assertEq(l.raised(), 9 ether);

        // An entity revocation does qualify.
        vm.prank(admin);
        registry.revokeEntity(leiB, "TEL");
        vm.prank(bob1);
        l.withdrawContribution();
        assertEq(l.raised(), 4 ether);
    }

    function test_withdrawWhenMovedToAnotherEntity() public {
        VLEIMintLauncher l = _launcher();
        _contribute(l, bob1, 1 ether);
        _register(bob1, leiC, ECR); // re-verified for another entity without a revocation
        vm.prank(bob1);
        l.withdrawContribution();
        assertEq(l.investedUsd(leiB), 0);
    }

    /// PoC: after a full withdraw, a wallet re-verified under a new LEI was locked out by a stale contributorLei.
    function test_contributorLeiClearedAfterWithdraw() public {
        VLEIMintLauncher l = _launcher();
        _contribute(l, bob1, 1 ether);
        vm.prank(admin);
        registry.revokeWallet(bob1, "moved");
        vm.prank(bob1);
        l.withdrawContribution();
        assertEq(l.contributorLei(bob1), bytes32(0));
        _register(bob1, leiC, ECR);
        _contribute(l, bob1, 1 ether);
        assertEq(l.investedUsd(leiC), 600e18);
    }

    // ── #7 implementation bound to the factory ──────────────────────────────

    function test_implementationBoundToFactory() public {
        assertEq(impl.factory(), address(factory));
        // A proxy of our beacon deployed by someone else cannot be initialized.
        address spoof = LibClone.deployERC1967BeaconProxy(factory.beacon());
        vm.expectRevert(abi.encodeWithSelector(VLEIMintLauncher.NotFactory.selector, address(this)));
        VLEIMintLauncher(payable(spoof)).initialize(address(portal), alice, _config(keccak256("spoof")));
        assertFalse(factory.isLauncher(spoof));
    }
}
