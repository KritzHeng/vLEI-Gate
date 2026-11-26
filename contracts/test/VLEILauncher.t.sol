// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LauncherFactoryBase} from "src/flap/LauncherFactoryBase.sol";
import {LauncherBase} from "src/flap/LauncherBase.sol";
import {LauncherDataSchema} from "src/flap/IVaultSchemas.sol";
import {LaunchExtensionHelper} from "src/flap/LaunchExtensionHelper.sol";

import {VLEIRegistry} from "../src/VLEIRegistry.sol";
import {VLEILauncherFactory} from "../src/VLEILauncherFactory.sol";
import {VLEIMintLauncher, VLEIMintConfig} from "../src/VLEIMintLauncher.sol";
import {MockPriceFeed} from "../src/mocks/MockPriceFeed.sol";
import {IVLEIRegistry} from "../src/interfaces/IVLEIRegistry.sol";
import {IPriceFeed} from "../src/interfaces/IPriceFeed.sol";
import {MockPortal} from "./mocks/MockPortal.sol";
import {RegistryHelper} from "./utils/RegistryHelper.sol";

contract VLEILauncherTest is RegistryHelper {
    MockPortal portal;
    MockPriceFeed feed;
    VLEILauncherFactory factory;
    VLEIMintLauncher impl;

    address admin = makeAddr("admin");
    address guardian = makeAddr("guardian");

    address alice = makeAddr("aliceOfficer"); //     OOR officer of issuer entity: may create
    address treasurer = makeAddr("oorTreasurer"); // OOR, not officer: may not create
    address ecrIssuer = makeAddr("ecrIssuer"); //    ECR: may not create
    address bob1 = makeAddr("bob1"); //              entity B, wallet 1
    address bob2 = makeAddr("bob2"); //              entity B, wallet 2
    address carol = makeAddr("carol"); //            entity C
    address outsider = makeAddr("outsider"); //      never verified

    bytes32 issuerLei = keccak256("5493001KJTIIGC8Y1R12");
    bytes32 leiB = keccak256("984500E1B2C3D4E5F617");
    bytes32 leiC = keccak256("529900T8BM49AURSDO55");

    uint256 constant TARGET = 10 ether;
    uint256 constant CAP_USD = 4_000e18; // $4,000 per entity; at $600/BNB = 6.666 BNB

    function setUp() public {
        vm.warp(1_750_000_000);
        registry = new VLEIRegistry(admin, vm.addr(verifierPk));
        feed = new MockPriceFeed(8, 600e8);
        portal = new MockPortal();
        factory = new VLEILauncherFactory(
            address(portal),
            guardian,
            IVLEIRegistry(address(registry)),
            IPriceFeed(address(feed)),
            1 hours,
            admin
        );
        impl = VLEIMintLauncher(payable(factory.beaconImplementation()));
        portal.setLauncherFactoryMultiplier(address(factory), 10_000, true);

        _register(alice, issuerLei, OFFICER);
        _register(treasurer, issuerLei, OOR);
        _register(ecrIssuer, issuerLei, ECR);
        _register(bob1, leiB, ECR);
        _register(bob2, leiB, OOR);
        _register(carol, leiC, ECR);

        address[7] memory all = [alice, treasurer, ecrIssuer, bob1, bob2, carol, outsider];
        for (uint256 i; i < all.length; ++i) {
            vm.deal(all[i], 100 ether);
        }
    }

    // ── helpers ─────────────────────────────────────────────────────────────

    function _config(bytes32 salt) internal pure returns (VLEIMintConfig memory c) {
        c.name = "Siam T-Bill 2027";
        c.symbol = "STB27";
        c.meta = "ipfs://offering";
        c.salt = salt;
        c.targetRaise = TARGET;
        c.saleDuration = 1 days;
        c.capUsdPerEntity = CAP_USD;
    }

    function _create(address who, bytes32 salt) internal returns (VLEIMintLauncher) {
        uint256 fee = portal.SALT_LOCK_FEE();
        vm.prank(who);
        return VLEIMintLauncher(payable(portal.newLauncher{value: fee}(address(factory), abi.encode(_config(salt)))));
    }

    function _launcher() internal returns (VLEIMintLauncher) {
        return _create(alice, keccak256("salt-1"));
    }

    function _contribute(VLEIMintLauncher l, address who, uint256 amount) internal {
        vm.prank(who);
        l.contribute{value: amount}();
    }

    // ── factory ─────────────────────────────────────────────────────────────

    function test_officerCreatesViaPortal() public {
        bytes32 salt = keccak256("salt-1");
        address predicted = factory.predictLauncher(alice, salt);
        VLEIMintLauncher l = _create(alice, salt);
        assertEq(address(l), predicted);
        assertEq(l.creator(), alice);
        assertEq(l.hub(), address(portal));
        assertEq(l.factory(), address(factory));
        assertEq(address(l.registry()), address(registry));
        assertEq(address(l.priceFeed()), address(feed));
        assertEq(l.capUsdPerEntity(), CAP_USD);
        assertEq(l.targetRaise(), TARGET);
        assertEq(l.saleDeadline(), block.timestamp + 1 days);
        assertEq(portal.saltLocker(salt), address(l), "the launcher locked its own salt");
        assertEq(factory.launcherCount(), 1);
        assertTrue(factory.isLauncher(address(l)));
        assertEq(l.status(), 0);
        assertTrue(l.creatorActive());
    }

    function test_nonOfficersCannotCreate() public {
        uint256 fee = portal.SALT_LOCK_FEE();
        bytes memory data = abi.encode(_config(keccak256("x")));
        address[3] memory denied = [ecrIssuer, treasurer, outsider];
        for (uint256 i; i < denied.length; ++i) {
            vm.prank(denied[i]);
            vm.expectRevert(abi.encodeWithSelector(VLEILauncherFactory.CreatorNotAuthorized.selector, denied[i]));
            portal.newLauncher{value: fee}(address(factory), data);
        }
    }

    function test_revokedOfficerCannotCreate() public {
        vm.prank(admin);
        registry.revokeWallet(alice, "OOR revoked");
        uint256 fee = portal.SALT_LOCK_FEE();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(VLEILauncherFactory.CreatorNotAuthorized.selector, alice));
        portal.newLauncher{value: fee}(address(factory), abi.encode(_config(keccak256("x"))));
    }

    function test_factoryOnlyCallableByHub() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LauncherFactoryBase.NotHub.selector, alice));
        factory.newLauncher(alice, abi.encode(_config(keccak256("x"))));
    }

    function test_upgradeOnlyGuardian() public {
        VLEIMintLauncher l = _launcher();
        VLEIMintLauncher impl2 = new VLEIMintLauncher(address(factory));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(LauncherFactoryBase.NotGuardian.selector, admin));
        factory.upgradeVaultImplementation(address(impl2));

        vm.prank(guardian);
        factory.upgradeVaultImplementation(address(impl2));
        assertEq(factory.beaconImplementation(), address(impl2));
        assertEq(l.creator(), alice, "state survives the upgrade");
    }

    function test_setMaxPriceAge() public {
        vm.prank(alice);
        vm.expectRevert();
        factory.setMaxPriceAge(2 hours);
        vm.startPrank(admin);
        vm.expectRevert(VLEILauncherFactory.InvalidMaxPriceAge.selector);
        factory.setMaxPriceAge(0);
        factory.setMaxPriceAge(2 hours);
        vm.stopPrank();
        assertEq(factory.maxPriceAge(), 2 hours);
        assertEq(_launcher().maxPriceAge(), 2 hours, "launchers read it live");
    }

    function test_schema() public view {
        LauncherDataSchema memory s = factory.launcherDataSchema();
        assertEq(s.fields.length, 7);
        assertEq(s.fields[6].name, "capUsdPerEntity");
        assertEq(s.fields[6].decimals, 18);
        assertEq(s.fields[4].decimals, 18);
        assertFalse(s.isArray);
        assertEq(factory.factorySpecVersion(), "lf-v1");
    }

    function test_initializeRejectsZeroCap() public {
        VLEIMintConfig memory c = _config(keccak256("x"));
        c.capUsdPerEntity = 0;
        uint256 fee = portal.SALT_LOCK_FEE();
        vm.prank(alice);
        vm.expectRevert(VLEIMintLauncher.InvalidConfig.selector);
        portal.newLauncher{value: fee}(address(factory), abi.encode(c));
    }

    function test_implementationCannotBeInitialized() public {
        vm.expectRevert();
        impl.initialize(address(portal), alice, _config(keccak256("x")));
    }

    // ── contribute ──────────────────────────────────────────────────────────

    function test_unverifiedContributeReverts() public {
        VLEIMintLauncher l = _launcher();
        vm.prank(outsider);
        vm.expectRevert(VLEIMintLauncher.NotVerified.selector);
        l.contribute{value: 1 ether}();
    }

    function test_contributeRevertsWhenCreatorRevoked() public {
        VLEIMintLauncher l = _launcher();
        vm.prank(admin);
        registry.revokeEntity(issuerLei, "TEL revocation");
        assertFalse(l.creatorActive());
        vm.prank(bob1);
        vm.expectRevert(VLEIMintLauncher.IssuerNotActive.selector);
        l.contribute{value: 1 ether}();
    }

    function test_capPerEntityAcrossWallets() public {
        VLEIMintLauncher l = _launcher();
        _contribute(l, bob1, 5 ether); // $3,000
        assertEq(l.investedUsd(leiB), 3_000e18);
        assertEq(l.remainingCapUsd(bob2), 1_000e18, "the second wallet sees the shared entity cap");
        assertEq(l.remainingCapUsd(carol), CAP_USD, "another entity is unaffected");

        vm.prank(bob2);
        vm.expectRevert(abi.encodeWithSelector(VLEIMintLauncher.CapExceeded.selector, 3_000e18, 1_200e18, CAP_USD));
        l.contribute{value: 2 ether}(); // $1,200 > $1,000 left

        _contribute(l, bob2, 1 ether); // $600 fits
        assertEq(l.investedUsd(leiB), 3_600e18);
        assertEq(l.contributedUsdOf(bob2), 600e18);
        assertEq(l.maxContribution(bob2), uint256(400e18) * 1e18 / 600e18);
    }

    function test_stalePriceReverts() public {
        VLEIMintLauncher l = _launcher();
        vm.warp(block.timestamp + 2 hours);
        assertEq(l.bnbUsdPrice(), 0, "soft view returns 0 when stale");
        vm.prank(bob1);
        vm.expectRevert(VLEIMintLauncher.StalePrice.selector);
        l.contribute{value: 1 ether}();
    }

    function test_invalidPriceReverts() public {
        VLEIMintLauncher l = _launcher();
        feed.setAnswer(0);
        assertEq(l.bnbUsdPrice(), 0);
        vm.prank(bob1);
        vm.expectRevert(VLEIMintLauncher.InvalidPrice.selector);
        l.contribute{value: 1 ether}();
    }

    function test_priceViews() public {
        VLEIMintLauncher l = _launcher();
        assertEq(l.bnbUsdPrice(), 600e18);
        assertEq(l.priceUpdatedAt(), block.timestamp);
        assertEq(l.quoteUsd(0.5 ether), 300e18);
    }

    // ── withdrawContribution ────────────────────────────────────────────────

    function test_withdrawContributionWhenRevokedBeforeLaunch() public {
        VLEIMintLauncher l = _launcher();
        _contribute(l, bob1, 5 ether);
        _contribute(l, carol, 2 ether);

        vm.prank(bob1);
        vm.expectRevert(VLEIMintLauncher.StillVerified.selector);
        l.withdrawContribution();

        vm.prank(admin);
        registry.revokeWallet(bob1, "ECR revoked");
        assertEq(l.vleiStatusOf(bob1), 3);

        uint256 before = bob1.balance;
        vm.prank(bob1);
        l.withdrawContribution();
        assertEq(bob1.balance - before, 5 ether);
        assertEq(l.raised(), 2 ether);
        assertEq(l.contributionOf(bob1), 0);
        assertEq(l.investedUsd(leiB), 0, "entity cap is freed");
        assertEq(address(l).balance, 2 ether);

        // The entity's other (still active) wallet can use the freed cap.
        assertEq(l.remainingCapUsd(bob2), CAP_USD);
        _contribute(l, bob2, 6 ether);

        vm.prank(bob1);
        vm.expectRevert(VLEIMintLauncher.NothingToWithdraw.selector);
        l.withdrawContribution();
    }

    // ── cancel + refund ─────────────────────────────────────────────────────

    function test_cancelIfCreatorRevokedThenRefund() public {
        VLEIMintLauncher l = _launcher();
        _contribute(l, bob1, 3 ether);
        _contribute(l, carol, 2 ether);

        vm.prank(outsider);
        vm.expectRevert(VLEIMintLauncher.IssuerStillActive.selector);
        l.cancelIfCreatorRevoked();

        vm.prank(bob1);
        vm.expectRevert(VLEIMintLauncher.RefundUnavailable.selector);
        l.refund();

        vm.prank(admin);
        registry.revokeWallet(alice, "OOR revoked");
        vm.prank(outsider); // anyone
        l.cancelIfCreatorRevoked();
        assertTrue(l.cancelled());
        assertEq(l.status(), 3);

        vm.prank(outsider);
        vm.expectRevert(VLEIMintLauncher.AlreadyCancelled.selector);
        l.cancelIfCreatorRevoked();

        vm.prank(carol);
        vm.expectRevert(VLEIMintLauncher.SaleIsCancelled.selector);
        l.contribute{value: 1 ether}();

        uint256 b = bob1.balance;
        uint256 c = carol.balance;
        vm.prank(bob1);
        l.refund();
        vm.prank(carol);
        l.refund();
        assertEq(bob1.balance - b, 3 ether);
        assertEq(carol.balance - c, 2 ether);
        assertEq(address(l).balance, 0);
        assertEq(l.raised(), 0);
    }

    function test_refundAfterFailedRound() public {
        VLEIMintLauncher l = _launcher();
        _contribute(l, bob1, 3 ether);
        vm.warp(block.timestamp + 1 days);
        assertEq(l.status(), 2);
        vm.prank(bob1);
        l.refund();
        assertEq(bob1.balance, 100 ether);
    }

    // ── launch + claim ──────────────────────────────────────────────────────

    function test_reachTargetLaunchesAndClaims() public {
        VLEIMintLauncher l = _launcher();
        _contribute(l, bob1, 4 ether);
        assertFalse(l.launched());
        _contribute(l, carol, 6 ether);

        assertTrue(l.launched());
        assertEq(l.status(), 1);
        assertEq(portal.lastCommissionReceiver(), address(0), "no developer commission");
        (bytes32 extId, bytes memory extData) = LaunchExtensionHelper.encodeCreator(alice);
        assertEq(portal.lastExtensionId(), extId);
        assertEq(portal.lastExtensionData(), extData);
        address token = l.token();
        uint256 reserved = l.TOTAL_SUPPLY() - l.POOL_TOKEN();
        assertEq(IERC20(token).balanceOf(address(l)), reserved);
        assertEq(l.claimableOf(bob1), reserved * 4 / 10);

        vm.prank(bob1);
        l.claim();
        vm.prank(carol);
        l.claim();
        assertEq(IERC20(token).balanceOf(bob1), reserved * 4 / 10);
        assertEq(IERC20(token).balanceOf(carol), reserved * 6 / 10);
        assertEq(l.claimableOf(bob1), 0);

        vm.prank(bob1);
        vm.expectRevert(VLEIMintLauncher.NothingToClaim.selector);
        l.claim();

        vm.prank(bob1);
        vm.expectRevert(VLEIMintLauncher.AlreadyLaunched.selector);
        l.contribute{value: 1 ether}();

        vm.prank(admin);
        registry.revokeWallet(alice, "late");
        vm.expectRevert(VLEIMintLauncher.AlreadyLaunched.selector);
        l.cancelIfCreatorRevoked();
    }

    /// Regression (review #4): an over-sized final contribution is trimmed to the remainder and the excess is
    /// returned, so a 1-wei front-run cannot make the target-filling contribution revert.
    function test_excessIsRefundedAndFrontRunCannotBlockTheLaunch() public {
        VLEIMintLauncher l = _launcher();
        _contribute(l, bob1, 6 ether);
        _contribute(l, bob2, 1); // front-run with 1 wei
        uint256 before = carol.balance;
        vm.prank(carol);
        l.contribute{value: 4 ether}();
        assertTrue(l.launched());
        assertEq(l.contributionOf(carol), 4 ether - 1);
        assertEq(before - carol.balance, 4 ether - 1, "excess returned in the same call");
        assertEq(address(l).balance, 0, "the whole raise went to the Portal");
    }

    function test_claimRevertsWhenRevokedAndWorksAfterReRegistration() public {
        VLEIMintLauncher l = _launcher();
        _contribute(l, bob1, 4 ether);
        _contribute(l, carol, 6 ether);
        assertTrue(l.launched());

        vm.prank(admin);
        registry.revokeWallet(carol, "ECR revoked");
        vm.prank(carol);
        vm.expectRevert(VLEIMintLauncher.NotVerified.selector);
        l.claim();
        uint256 owed = l.claimableOf(carol);
        assertGt(owed, 0, "tokens stay reserved");

        // Withdraw is no longer possible after the launch.
        vm.prank(carol);
        vm.expectRevert(VLEIMintLauncher.AlreadyLaunched.selector);
        l.withdrawContribution();

        _register(carol, leiC, ECR); // re-verified on the bumped nonce
        vm.prank(carol);
        l.claim();
        assertEq(IERC20(l.token()).balanceOf(carol), owed);
    }

    function test_distributionCallbackOnlyFromHubDuringLaunch() public {
        VLEIMintLauncher l = _launcher();
        vm.expectRevert(abi.encodeWithSelector(LauncherBase.NotHub.selector, address(this)));
        l.initializeDistribution(address(1), 1, "", bytes32(0));
        vm.prank(address(portal));
        vm.expectRevert(VLEIMintLauncher.UnauthorizedDistribution.selector);
        l.initializeDistribution(address(1), 1, "", bytes32(0));
    }

    // ── vLEI views ──────────────────────────────────────────────────────────

    function test_vleiViews() public {
        VLEIMintLauncher l = _launcher();
        assertEq(l.vleiStatusOf(outsider), 0);
        assertEq(l.vleiStatusOf(bob1), 1);
        assertEq(l.vleiRoleOf(alice), 3);
        assertEq(l.vleiRoleOf(bob1), 1);
        assertEq(l.vleiExpiresAt(bob1), block.timestamp + 7 days);
        assertEq(l.remainingCapUsd(outsider), 0);

        vm.prank(admin);
        registry.revokeEntity(leiC, "TEL");
        assertEq(l.vleiStatusOf(carol), 4);

        vm.warp(block.timestamp + 7 days);
        assertEq(l.vleiStatusOf(bob1), 2);
        assertEq(l.status(), 2);
    }

    function test_descriptionJson() public {
        VLEIMintLauncher l = _launcher();
        string memory d = l.description();
        assertTrue(bytes(d).length > 0);
        assertTrue(_contains(d, '"name":"Siam T-Bill 2027"'));
        assertTrue(_contains(d, '"targetRaise":"10000000000000000000"'));
    }

    function _contains(string memory h, string memory n) internal pure returns (bool) {
        bytes memory hb = bytes(h);
        bytes memory nb = bytes(n);
        if (nb.length > hb.length) return false;
        for (uint256 i; i <= hb.length - nb.length; ++i) {
            bool ok = true;
            for (uint256 j; j < nb.length; ++j) {
                if (hb[i + j] != nb[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }
}
