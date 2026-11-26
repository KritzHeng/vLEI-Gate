// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPortalTypes} from "src/flap/IPortal.sol";
import {Distribution} from "src/flap/Distribution.sol";
import {DirectLaunchVaultFactoryBase} from "src/flap/DirectLaunchVaultFactoryBase.sol";
import {VaultUISchema} from "src/flap/IVaultSchemas.sol";

import {VLEIRegistry} from "../src/VLEIRegistry.sol";
import {VLEIMintConfig} from "../src/VLEIMintLauncher.sol";
import {VLEIMintVaultLauncher} from "../src/VLEIMintVaultLauncher.sol";
import {VLEIVaultLauncherFactory} from "../src/VLEIVaultLauncherFactory.sol";
import {VLEIDividendVault} from "../src/vault/VLEIDividendVault.sol";
import {VLEIDividendVaultFactory} from "../src/vault/VLEIDividendVaultFactory.sol";
import {VLEILauncherFactory} from "../src/VLEILauncherFactory.sol";
import {MockPriceFeed} from "../src/mocks/MockPriceFeed.sol";
import {IVLEIRegistry} from "../src/interfaces/IVLEIRegistry.sol";
import {IPriceFeed} from "../src/interfaces/IPriceFeed.sol";
import {MockVaultPortal} from "./mocks/MockVaultPortal.sol";
import {RegistryHelper} from "./utils/RegistryHelper.sol";

contract VLEIDividendVaultTest is RegistryHelper {
    MockVaultPortal portal;
    MockPriceFeed feed;
    VLEIDividendVaultFactory vaultFactory;
    VLEIVaultLauncherFactory factory;

    address admin = makeAddr("admin");
    address guardian = makeAddr("guardian");

    address alice = makeAddr("aliceOfficer"); // OOR officer: creates the launch
    address bob = makeAddr("bob"); //            entity B
    address carol = makeAddr("carol"); //        entity C
    address dave = makeAddr("dave"); //          entity D (late staker)
    address outsider = makeAddr("outsider"); //  never verified, buys on the DEX

    bytes32 issuerLei = keccak256("ISSUER");
    bytes32 leiB = keccak256("LEI-B");
    bytes32 leiC = keccak256("LEI-C");
    bytes32 leiD = keccak256("LEI-D");

    VLEIMintVaultLauncher launcher;
    VLEIDividendVault vault;
    IERC20 token;

    function setUp() public {
        vm.warp(1_750_000_000);
        registry = new VLEIRegistry(admin, vm.addr(verifierPk));
        feed = new MockPriceFeed(8, 600e8);
        portal = new MockVaultPortal();

        (vaultFactory, factory) = _deployPair();
        portal.setLauncherFactoryMultiplier(address(factory), 10_000, true);

        _register(alice, issuerLei, OFFICER);
        _register(bob, leiB, ECR);
        _register(carol, leiC, ECR);
        _register(dave, leiD, OOR);
        vm.deal(alice, 1 ether);
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);
        vm.deal(address(this), 1000 ether);
    }

    function _deployPair() internal returns (VLEIDividendVaultFactory vf, VLEIVaultLauncherFactory lf) {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        vf = new VLEIDividendVaultFactory(address(portal), guardian, predicted);
        lf = new VLEIVaultLauncherFactory(
            address(portal), guardian, IVLEIRegistry(address(registry)), IPriceFeed(address(feed)), 1 hours, admin,
            address(vf)
        );
        assertEq(address(lf), predicted, "address prediction held");
    }

    function _config(bytes32 salt) internal pure returns (VLEIMintConfig memory c) {
        c.name = "Siam T-Bill 2027";
        c.symbol = "STB27";
        c.meta = "ipfs://meta";
        c.salt = salt;
        c.targetRaise = 10 ether;
        c.saleDuration = 1 days;
        c.capUsdPerEntity = 5_000e18;
    }

    function _newLauncher(bytes32 salt) internal returns (VLEIMintVaultLauncher l) {
        vm.prank(alice);
        l = VLEIMintVaultLauncher(payable(portal.newLauncher{value: 0.005 ether}(address(factory), abi.encode(_config(salt)))));
    }

    /// @dev Launch with bob 4 BNB and carol 6 BNB, both claim their tokens (200k / 300k), and the outsider gets
    ///      50k tokens "from the DEX" (here: from bob).
    function _launch() internal {
        launcher = _newLauncher("s1");
        vm.prank(bob);
        launcher.contribute{value: 4 ether}();
        vm.prank(carol);
        launcher.contribute{value: 6 ether}();
        assertTrue(launcher.launched());
        vault = VLEIDividendVault(payable(launcher.vault()));
        token = IERC20(launcher.token());
        vm.prank(bob);
        launcher.claim();
        vm.prank(carol);
        launcher.claim();
        vm.prank(bob);
        token.transfer(outsider, 50_000 ether);
    }

    function _stake(address who, uint256 amount) internal {
        vm.startPrank(who);
        token.approve(address(vault), amount);
        vault.stake(amount);
        vm.stopPrank();
    }

    function _pay(uint256 amount) internal {
        portal.dispatchToVault{value: amount}(address(token));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Wiring
    // ─────────────────────────────────────────────────────────────────────────

    function test_pairing_rejectsUnpairedVaultFactory() public {
        VLEIDividendVaultFactory other = new VLEIDividendVaultFactory(address(portal), guardian, address(0xBEEF));
        vm.expectRevert(abi.encodeWithSelector(VLEIVaultLauncherFactory.VaultFactoryNotPaired.selector, address(other)));
        new VLEIVaultLauncherFactory(
            address(portal), guardian, IVLEIRegistry(address(registry)), IPriceFeed(address(feed)), 1 hours, admin,
            address(other)
        );
        assertEq(factory.vaultFactory(), address(vaultFactory));
        assertEq(vaultFactory.launcherFactory(), address(factory));
        assertEq(vaultFactory.factorySpecVersion(), "pl-v1");
        assertTrue(vaultFactory.isQuoteTokenSupported(address(0)));
        assertFalse(vaultFactory.isQuoteTokenSupported(address(0x1234)));
    }

    function test_launch_usesVaultSlotInsteadOfDividend_noCommission() public {
        _launch();
        assertEq(portal.lastCommissionReceiver(), address(0), "no developer commission");
        assertEq(portal.lastFeeCount(), 3);
        IPortalTypes.FeeConfig memory f0 = portal.lastFee(0);
        IPortalTypes.FeeConfig memory f1 = portal.lastFee(1);
        IPortalTypes.FeeConfig memory f2 = portal.lastFee(2);
        assertEq(uint8(f0.feeType), uint8(IPortalTypes.FeeSlotType.DEFLATION));
        assertEq(f0.bps, 1000);
        assertEq(uint8(f1.feeType), uint8(IPortalTypes.FeeSlotType.LP_BPS));
        assertEq(f1.bps, 1500);
        assertEq(uint8(f2.feeType), uint8(IPortalTypes.FeeSlotType.VAULT));
        assertEq(f2.bps, 7500);
        IPortalTypes.FeeConfigVault memory v = abi.decode(f2.configData, (IPortalTypes.FeeConfigVault));
        assertEq(v.vaultFactory, address(vaultFactory));
        assertEq(abi.decode(v.vaultData, (address)), address(launcher));

        (address pv, address pf) = portal.getLaunchVault(address(token));
        assertEq(pv, address(vault));
        assertEq(pf, address(vaultFactory));
        assertEq(vaultFactory.vaultOf(address(token)), address(vault));
        assertEq(vaultFactory.predictVault(address(token)), address(vault));
        assertEq(vault.taxToken(), address(token));
        assertEq(vault.launcher(), address(launcher));
        assertEq(address(vault.registry()), address(registry));
        assertFalse(launcher.launching());
    }

    function test_launcherFactory_keepsTheVleiGate() public {
        vm.prank(bob); // ECR
        vm.expectRevert(abi.encodeWithSelector(VLEILauncherFactory.CreatorNotAuthorized.selector, bob));
        portal.newLauncher{value: 0.005 ether}(address(factory), abi.encode(_config("ecr")));

        launcher = _newLauncher("gate");
        vm.deal(outsider, 1 ether);
        vm.prank(outsider);
        vm.expectRevert(VLEIMintVaultLauncher.NotVerified.selector);
        launcher.contribute{value: 1 ether}();
    }

    function test_vaultImplementation_onlyFactoryInitializes() public {
        _launch();
        VLEIDividendVault impl = VLEIDividendVault(payable(vaultFactory.beaconImplementation()));
        vm.expectRevert(); // initializers disabled
        impl.initialize(address(token), address(launcher));
        vm.expectRevert(); // already initialized
        vault.initialize(address(token), address(launcher));
    }

    // ── newVault validation ─────────────────────────────────────────────────

    function _params(address vf, bytes memory vaultData, uint16 bps, address quote, address commission)
        internal
        pure
        returns (bytes memory)
    {
        IPortalTypes.FeeConfig[] memory fees = new IPortalTypes.FeeConfig[](2);
        fees[0] = IPortalTypes.FeeConfig({
            feeType: IPortalTypes.FeeSlotType.VAULT,
            bps: bps,
            configData: abi.encode(IPortalTypes.FeeConfigVault({vaultFactory: vf, vaultData: vaultData}))
        });
        fees[1] = IPortalTypes.FeeConfig({feeType: IPortalTypes.FeeSlotType.DEFLATION, bps: 10_000 - bps, configData: ""});
        IPortalTypes.CreateTaxTokenParams memory p;
        p.quoteToken = quote;
        p.commissionReceiver = commission;
        p.totalSupply = 1_000_000 ether;
        p.feeConfigs = fees;
        Distribution memory d;
        return abi.encode(p, d);
    }

    function test_newVault_onlyHub() public {
        bytes memory lp = _params(address(vaultFactory), abi.encode(address(1)), 7500, address(0), address(0));
        vm.expectRevert(abi.encodeWithSelector(DirectLaunchVaultFactoryBase.NotHub.selector, address(this)));
        vaultFactory.newVault(address(0x7777), address(1), 0, lp);
    }

    function test_newVault_rejectsBadLaunches() public {
        VLEIMintVaultLauncher l = _newLauncher("v"); // recorded, not launching
        address tok = address(0x7777);
        address vf = address(vaultFactory);
        bytes memory good = abi.encode(address(l));

        vm.startPrank(address(portal));
        // A caller the Portal never recorded as this family's launcher.
        vm.expectRevert(abi.encodeWithSelector(VLEIDividendVaultFactory.NotFromLauncherFactory.selector, alice));
        vaultFactory.newVault(tok, alice, 0, _params(vf, abi.encode(alice), 7500, address(0), address(0)));
        // vaultData naming another launcher.
        vm.expectRevert(
            abi.encodeWithSelector(VLEIDividendVaultFactory.VaultDataLauncherMismatch.selector, address(l), bob)
        );
        vaultFactory.newVault(tok, address(l), 0, _params(vf, abi.encode(bob), 7500, address(0), address(0)));
        // Trailing bytes in vaultData.
        vm.expectRevert(DirectLaunchVaultFactoryBase.InvalidVaultData.selector);
        vaultFactory.newVault(tok, address(l), 0, _params(vf, abi.encode(address(l), 1), 7500, address(0), address(0)));
        // Wrong slot size.
        vm.expectRevert(abi.encodeWithSelector(VLEIDividendVaultFactory.VaultSlotBpsMismatch.selector, 8000, 7500));
        vaultFactory.newVault(tok, address(l), 0, _params(vf, good, 8000, address(0), address(0)));
        // ERC20 quote.
        vm.expectRevert(
            abi.encodeWithSelector(DirectLaunchVaultFactoryBase.UnsupportedQuoteToken.selector, address(0x1234))
        );
        vaultFactory.newVault(tok, address(l), 0, _params(vf, good, 7500, address(0x1234), address(0)));
        // A commission receiver.
        vm.expectRevert(abi.encodeWithSelector(VLEIDividendVaultFactory.CommissionNotAllowed.selector, bob));
        vaultFactory.newVault(tok, address(l), 0, _params(vf, good, 7500, address(0), bob));
        // A recorded launcher that is not mid-launch.
        vm.expectRevert(abi.encodeWithSelector(VLEIDividendVaultFactory.LauncherNotLaunching.selector, address(l)));
        vaultFactory.newVault(tok, address(l), 0, _params(vf, good, 7500, address(0), address(0)));
        // Unsupported launch kind.
        vm.expectRevert(abi.encodeWithSelector(DirectLaunchVaultFactoryBase.UnsupportedLaunchKind.selector, 1));
        vaultFactory.newVault(tok, address(l), 1, _params(vf, good, 7500, address(0), address(0)));
        vm.stopPrank();
    }

    function test_upgrade_onlyGuardian_stateSurvives() public {
        _launch();
        _stake(bob, 100 ether);
        _pay(1 ether);
        VLEIDividendVault newImpl = new VLEIDividendVault(address(vaultFactory));

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(DirectLaunchVaultFactoryBase.NotGuardian.selector, admin));
        vaultFactory.upgradeVaultImplementation(address(newImpl));

        vm.prank(guardian);
        vaultFactory.upgradeVaultImplementation(address(newImpl));
        assertEq(vaultFactory.beaconImplementation(), address(newImpl));
        assertEq(vault.stakedOf(bob), 100 ether);
        assertApproxEqAbs(vault.claimable(bob), 1 ether, 1);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Gated yield
    // ─────────────────────────────────────────────────────────────────────────

    function test_unverifiedHolderCannotStake_andEarnsNothing() public {
        _launch();
        vm.startPrank(outsider);
        token.approve(address(vault), 50_000 ether);
        vm.expectRevert(VLEIDividendVault.NotVerified.selector);
        vault.stake(50_000 ether);
        vm.expectRevert(VLEIDividendVault.NotVerified.selector);
        vault.claim();
        vm.stopPrank();

        _stake(bob, 100 ether);
        _pay(3 ether);
        assertApproxEqAbs(vault.claimable(bob), 3 ether, 1, "the verified staker takes all of it");
        assertEq(vault.claimable(outsider), 0);
        assertEq(vault.pendingRewards(outsider), 0);
    }

    function test_revenueSplitsProRata_andClaim() public {
        _launch();
        _stake(bob, 100 ether);
        _stake(carol, 300 ether);
        _pay(4 ether);
        assertEq(vault.totalRevenue(), 4 ether);
        assertApproxEqAbs(vault.claimable(bob), 1 ether, 1);
        assertApproxEqAbs(vault.claimable(carol), 3 ether, 1);

        uint256 b0 = bob.balance;
        vm.prank(bob);
        uint256 paid = vault.claim();
        assertEq(bob.balance - b0, paid);
        assertApproxEqAbs(paid, 1 ether, 1);
        vm.prank(bob);
        vm.expectRevert(VLEIDividendVault.NothingToClaim.selector);
        vault.claim();

        uint256 c0 = carol.balance;
        vm.prank(carol);
        vault.claim();
        assertApproxEqAbs(carol.balance - c0, 3 ether, 1);
        assertLe(vault.totalClaimed(), vault.totalRevenue());
        assertEq(vault.accountedBalance(), address(vault).balance);
    }

    function test_lateStakerDoesNotGetPastRevenue() public {
        _launch();
        _stake(bob, 100 ether);
        _pay(2 ether);
        // dave holds no tokens yet: give him some from carol (an OTC buy).
        vm.prank(carol);
        token.transfer(dave, 100 ether);
        _stake(dave, 100 ether);
        assertEq(vault.claimable(dave), 0, "nothing from before the stake");
        _pay(2 ether);
        assertApproxEqAbs(vault.claimable(bob), 3 ether, 2);
        assertApproxEqAbs(vault.claimable(dave), 1 ether, 2);
    }

    function test_revenueWithNoStakers_isHeldForTheNextStakers() public {
        _launch();
        _pay(5 ether);
        assertEq(vault.undistributed(), 5 ether);
        // A small stake cannot sweep held revenue (review finding: first 1-token staker took everything).
        _stake(bob, 100 ether);
        assertEq(vault.pendingRewards(bob), 0, "held revenue not released below the threshold");
        assertEq(vault.claimable(bob), 0);
        vault.sync();
        assertEq(vault.undistributed(), 5 ether, "still held");
        // Once HELD_RELEASE_MIN_STAKE is staked, the held revenue goes to the stakers at that point.
        _stake(bob, vault.HELD_RELEASE_MIN_STAKE() - 100 ether);
        assertApproxEqAbs(vault.pendingRewards(bob), 5 ether, 1, "view includes the held revenue");
        assertApproxEqAbs(vault.claimable(bob), 5 ether, 1, "claimable mirrors claim");
        vm.prank(bob);
        vault.claim();
        assertEq(vault.undistributed(), 0);
    }

    function test_leiHop_cannotCarryRevokedEntityRewards() public {
        _launch();
        _stake(bob, 100 ether);
        _stake(carol, 100 ether);
        _pay(2 ether);
        vm.prank(bob);
        vault.unstake(100 ether); // owed ~1 BNB stays, LEI stays bob's
        assertGt(vault.pendingRewards(bob), 0);
        // bob's wallet is re-attested under another entity's LEI
        _register(bob, keccak256("OTHER-LEI"), 1);
        vm.startPrank(bob);
        vm.expectRevert(VLEIDividendVault.EntityMismatch.selector);
        vault.stake(1 ether);
        vm.expectRevert(VLEIDividendVault.NotVerified.selector);
        vault.claim();
        vm.stopPrank();
        assertTrue(vault.evictable(bob), "LEI moved: forfeitable");
    }

    function test_expiry_doesNotForfeitRewardsAfterFullUnstake() public {
        _launch();
        _stake(bob, 100 ether);
        _stake(carol, 100 ether);
        _pay(2 ether);
        vm.prank(bob);
        vault.unstake(100 ether);
        uint256 owed = vault.pendingRewards(bob);
        assertGt(owed, 0);
        vm.warp(block.timestamp + 60 days); // registrations long expired
        assertFalse(vault.evictable(bob), "unstaked rewards survive expiry");
        _register(bob, vault.stakerLeiHash(bob), 1);
        vm.prank(bob);
        assertApproxEqAbs(vault.claim(), owed, 1);
    }

    function test_revokedWallet_cannotClaim_evictRedistributes() public {
        _launch();
        _stake(bob, 100 ether);
        _stake(carol, 100 ether);
        _pay(2 ether);

        vm.prank(admin);
        registry.revokeWallet(carol, "ECR revoked");
        assertFalse(vault.canClaim(carol));
        assertEq(vault.claimable(carol), 0);
        assertTrue(vault.evictable(carol));
        assertFalse(vault.evictable(bob));
        vm.prank(carol);
        vm.expectRevert(VLEIDividendVault.NotVerified.selector);
        vault.claim();

        // Anyone (here bob, who profits) evicts carol: her tokens go back, her 1 BNB is forfeited to bob.
        uint256 carolTokens = token.balanceOf(carol);
        vm.prank(bob);
        vault.evict(carol);
        assertEq(token.balanceOf(carol), carolTokens + 100 ether, "principal returned");
        assertEq(vault.stakedOf(carol), 0);
        assertEq(vault.totalForfeited(), 1 ether);
        assertEq(vault.totalStaked(), 100 ether);
        assertApproxEqAbs(vault.claimable(bob), 2 ether, 2, "bob gets carol's forfeited share");

        // Future revenue goes only to bob.
        _pay(1 ether);
        assertApproxEqAbs(vault.claimable(bob), 3 ether, 2);
        vm.prank(bob);
        vault.claim();
        assertLe(address(vault).balance, 5);

        vm.expectRevert(abi.encodeWithSelector(VLEIDividendVault.NotEvictable.selector, bob));
        vault.evict(bob);
        vm.expectRevert(abi.encodeWithSelector(VLEIDividendVault.NotEvictable.selector, carol));
        vault.evict(carol); // already out
    }

    function test_revokedEntity_evictable_andRevokedCannotStake() public {
        _launch();
        _stake(bob, 100 ether);
        _stake(carol, 100 ether);
        vm.prank(admin);
        registry.revokeEntity(leiC, "TEL revocation");
        assertTrue(vault.evictable(carol));
        vm.startPrank(carol);
        token.approve(address(vault), 1 ether);
        vm.expectRevert(VLEIDividendVault.NotVerified.selector);
        vault.stake(1 ether);
        vm.stopPrank();
        vault.evict(carol);
        assertEq(vault.totalStaked(), 100 ether);
    }

    function test_revokedStakerUnstake_isFullExitAndForfeits() public {
        _launch();
        _stake(bob, 100 ether);
        _stake(carol, 300 ether);
        _pay(4 ether);
        vm.prank(admin);
        registry.revokeWallet(carol, "ECR revoked");
        uint256 before = token.balanceOf(carol);
        vm.prank(carol);
        vault.unstake(1 ether); // asks for 1, gets the whole position back
        assertEq(token.balanceOf(carol) - before, 300 ether, "principal never trapped");
        assertApproxEqAbs(vault.totalForfeited(), 3 ether, 1);
        assertApproxEqAbs(vault.claimable(bob), 4 ether, 2);
    }

    function test_activeUnstake_keepsEarnedRewards() public {
        _launch();
        _stake(bob, 100 ether);
        _stake(carol, 100 ether);
        _pay(2 ether);
        vm.prank(bob);
        vault.unstake(100 ether);
        assertEq(vault.stakedOf(bob), 0);
        assertApproxEqAbs(vault.claimable(bob), 1 ether, 1, "earned before unstaking");
        _pay(2 ether);
        assertApproxEqAbs(vault.claimable(bob), 1 ether, 1, "nothing after unstaking");
        assertApproxEqAbs(vault.claimable(carol), 3 ether, 2);
        vm.prank(bob);
        vault.claim();

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(VLEIDividendVault.BelowMinStake.selector, 0.5 ether, 1 ether));
        vault.unstake(99.5 ether);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(VLEIDividendVault.InsufficientStake.selector, 101 ether, 100 ether));
        vault.unstake(101 ether);
    }

    function test_expiry_pausesClaims_graceThenEvictable() public {
        _launch();
        _stake(bob, 100 ether);
        _stake(carol, 100 ether);
        _pay(2 ether);
        vm.warp(block.timestamp + 7 days); // registrations expire (7-day attestations in RegistryHelper)
        assertFalse(registry.isActive(carol));
        assertFalse(vault.canClaim(carol));
        assertFalse(vault.evictable(carol), "a lapse alone is not a revocation");
        assertTrue(vault.isEarning(carol));
        _pay(2 ether); // still accrues during the grace period

        // carol renews and claims everything; bob does not.
        _register(carol, leiC, ECR);
        vm.prank(carol);
        vault.claim();
        vm.warp(block.timestamp + vault.EXPIRY_GRACE());
        assertTrue(vault.evictable(bob));
        vault.evict(bob);
        assertApproxEqAbs(vault.totalForfeited(), 2 ether, 2);
    }

    function test_movedEntity_isEvictable_andCannotTopUp() public {
        _launch();
        _stake(carol, 100 ether);
        _register(carol, leiD, ECR); // re-registered under another LEI
        assertTrue(vault.evictable(carol));
        assertFalse(vault.canClaim(carol));
        vm.startPrank(carol);
        token.approve(address(vault), 10 ether);
        vm.expectRevert(VLEIDividendVault.EntityMismatch.selector);
        vault.stake(10 ether);
        vm.stopPrank();
    }

    function test_minStake_andZero() public {
        _launch();
        vm.startPrank(bob);
        token.approve(address(vault), 10 ether);
        vm.expectRevert(abi.encodeWithSelector(VLEIDividendVault.BelowMinStake.selector, 0.5 ether, 1 ether));
        vault.stake(0.5 ether);
        vm.expectRevert(VLEIDividendVault.ZeroAmount.selector);
        vault.stake(0);
        vm.stopPrank();
    }

    function test_spuriousPingsAndForcedBnb_creditedOnce() public {
        _launch();
        _stake(bob, 100 ether);
        (bool ok,) = address(vault).call("");
        assertTrue(ok);
        (ok,) = address(vault).call("");
        assertTrue(ok);
        assertEq(vault.totalRevenue(), 0);
        vm.deal(address(vault), 1 ether); // arrives without a wake
        assertApproxEqAbs(vault.pendingRewards(bob), 1 ether, 1, "view sees unsynced revenue");
        vault.sync();
        vault.sync();
        assertEq(vault.totalRevenue(), 1 ether);
    }

    function test_receive_isCheap() public {
        _launch();
        _stake(bob, 100 ether);
        _pay(1 ether); // warm the slots
        uint256 g = gasleft();
        (bool ok,) = address(vault).call{value: 1 ether, gas: 60_000}("");
        uint256 used = g - gasleft();
        assertTrue(ok, "receive fits in 60k gas");
        emit log_named_uint("receive() gas incl. call", used);
    }

    function test_descriptionAndSchema() public {
        _launch();
        string memory d = vault.description();
        assertTrue(bytes(d).length > 0 && bytes(d).length < 4096);
        emit log_string(d);
        VaultUISchema memory s = vault.vaultUISchema();
        assertEq(s.vaultType, "VLEIDividendVault");
        assertEq(s.methods.length, 7);
        assertEq(s.methods[0].approvals[0].tokenType, "taxToken");
        assertTrue(bytes(launcher.description()).length < 4096);
        assertEq(vault.version(), "v1.0.0");
    }

    /// @dev Many stakers, random revenue lumps and churn: the vault never pays more than it received, and each
    ///      staker's payout matches its pro-rata share within rounding dust.
    function testFuzz_payoutsNeverExceedRevenue(uint96 a, uint96 b, uint96 c, uint64 r1, uint64 r2, uint64 r3) public {
        _launch();
        uint256 sa = bound(a, 1 ether, 150_000 ether);
        uint256 sb = bound(b, 1 ether, 150_000 ether);
        uint256 sc = bound(c, 1 ether, 50_000 ether);
        uint256 rev1 = bound(r1, 1, 50 ether);
        uint256 rev2 = bound(r2, 1, 50 ether);
        uint256 rev3 = bound(r3, 1, 50 ether);
        vm.prank(carol);
        token.transfer(dave, sc);

        _stake(bob, sa);
        _pay(rev1);
        _stake(carol, sb);
        _pay(rev2);
        _stake(dave, sc);
        vm.prank(admin);
        registry.revokeWallet(carol, "x");
        vault.evict(carol);
        _pay(rev3);

        uint256 paid;
        uint256 x0 = bob.balance;
        vm.prank(bob);
        try vault.claim() {} catch {}
        paid += bob.balance - x0;
        x0 = dave.balance;
        vm.prank(dave);
        try vault.claim() {} catch {}
        paid += dave.balance - x0;

        uint256 total = rev1 + rev2 + rev3;
        assertEq(vault.totalRevenue(), total);
        assertLe(paid, total, "never pays more than received");
        assertLe(total - paid, 10, "only rounding dust stays behind");
        assertEq(vault.accountedBalance(), address(vault).balance);
    }
}
