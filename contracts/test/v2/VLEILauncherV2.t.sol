// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LibString} from "solady/utils/LibString.sol";
import {IPortalTypes} from "src/flap/IPortal.sol";

import {VLEIRegistry} from "../../src/VLEIRegistry.sol";
import {VLEIMintConfig} from "../../src/VLEIMintLauncher.sol";
import {VLEILauncherBaseV2} from "../../src/v2/VLEILauncherBaseV2.sol";
import {VLEILauncherFactoryBaseV2} from "../../src/v2/VLEILauncherFactoryBaseV2.sol";
import {VLEILauncherFactoryV2} from "../../src/v2/VLEILauncherFactoryV2.sol";
import {VLEIMintLauncherV2} from "../../src/v2/VLEIMintLauncherV2.sol";
import {MockPriceFeed} from "../../src/mocks/MockPriceFeed.sol";
import {IVLEIRegistry} from "../../src/interfaces/IVLEIRegistry.sol";
import {IPriceFeed} from "../../src/interfaces/IPriceFeed.sol";
import {MockPortalV2} from "../mocks/MockPortalV2.sol";
import {MockQuoteToken} from "../mocks/MockQuoteToken.sol";
import {RegistryHelper} from "../utils/RegistryHelper.sol";

/// @notice v2 launcher with an ERC20 quote (mock USDT) and, for parity, with native BNB.
contract VLEILauncherV2Test is RegistryHelper {
    MockPortalV2 portal;
    MockPriceFeed feed;
    MockQuoteToken usdt;
    VLEILauncherFactoryV2 factory; //    USDT quote
    VLEILauncherFactoryV2 bnbFactory; // native quote

    address admin = makeAddr("admin");
    address guardian = makeAddr("guardian");
    address alice = makeAddr("aliceOfficer");
    address bob1 = makeAddr("bob1");
    address bob2 = makeAddr("bob2");
    address carol = makeAddr("carol");
    address outsider = makeAddr("outsider");

    bytes32 issuerLei = keccak256("5493001KJTIIGC8Y1R12");
    bytes32 leiB = keccak256("984500E1B2C3D4E5F617");
    bytes32 leiC = keccak256("529900T8BM49AURSDO55");

    uint256 constant TARGET = 2_000e18; // 2,000 USDT
    uint256 constant CAP = 1_200e18; // 1,200 USDT per entity

    function setUp() public {
        vm.warp(1_750_000_000);
        registry = new VLEIRegistry(admin, vm.addr(verifierPk));
        feed = new MockPriceFeed(8, 600e8);
        portal = new MockPortalV2();
        usdt = new MockQuoteToken("Mock USDT", "USD", 18);
        factory = new VLEILauncherFactoryV2(
            address(portal), guardian, IVLEIRegistry(address(registry)), IPriceFeed(address(0)), address(usdt), 1 hours, admin
        );
        bnbFactory = new VLEILauncherFactoryV2(
            address(portal), guardian, IVLEIRegistry(address(registry)), IPriceFeed(address(feed)), address(0), 1 hours, admin
        );

        _register(alice, issuerLei, OFFICER);
        _register(bob1, leiB, ECR);
        _register(bob2, leiB, OOR);
        _register(carol, leiC, ECR);

        address[5] memory all = [alice, bob1, bob2, carol, outsider];
        for (uint256 i; i < all.length; ++i) {
            vm.deal(all[i], 100 ether);
            usdt.mint(all[i], 10_000e18);
        }
    }

    // ── helpers ─────────────────────────────────────────────────────────────

    function _config(bytes32 salt, uint256 target, uint256 cap) internal pure returns (VLEIMintConfig memory c) {
        c.name = "Siam T-Bill 2027";
        c.symbol = "STB27";
        c.meta = "ipfs://offering";
        c.salt = salt;
        c.targetRaise = target;
        c.saleDuration = 1 days;
        c.capUsdPerEntity = cap;
    }

    function _create(VLEILauncherFactoryV2 f, VLEIMintConfig memory c) internal returns (VLEIMintLauncherV2) {
        uint256 fee = portal.SALT_LOCK_FEE();
        vm.prank(alice);
        return VLEIMintLauncherV2(payable(portal.newLauncher{value: fee}(address(f), abi.encode(c))));
    }

    function _launcher() internal returns (VLEIMintLauncherV2) {
        return _create(factory, _config(keccak256("salt-1"), TARGET, CAP));
    }

    function _approve(VLEIMintLauncherV2 l, address who, uint256 amount) internal {
        vm.prank(who);
        usdt.approve(address(l), amount);
    }

    function _approveAndContribute(VLEIMintLauncherV2 l, address who, uint256 amount) internal {
        _approve(l, who, amount);
        vm.prank(who);
        l.contribute();
    }

    // ── factory ─────────────────────────────────────────────────────────────

    function test_factory_quoteConfig() public view {
        assertEq(factory.quoteToken(), address(usdt));
        assertEq(address(factory.priceFeed()), address(0));
        assertEq(factory.minTargetUsd(), 1_500e18, "ERC20 default = Portal creation floor");
        assertEq(factory.quoteUsd(1_234e18), 1_234e18, "1 quote = $1");
        assertEq(bnbFactory.quoteToken(), address(0));
        assertEq(bnbFactory.minTargetUsd(), 1_600e18);
        assertEq(bnbFactory.quoteUsd(1 ether), 600e18);
    }

    function test_factory_rejectsFeedOnErc20_and_non18Decimals() public {
        vm.expectRevert(abi.encodeWithSelector(VLEILauncherFactoryBaseV2.PriceFeedNotUsed.selector, address(feed)));
        new VLEILauncherFactoryV2(
            address(portal), guardian, IVLEIRegistry(address(registry)), IPriceFeed(address(feed)), address(usdt), 1 hours, admin
        );
        MockQuoteToken six = new MockQuoteToken("USDC", "USDC", 6);
        vm.expectRevert(abi.encodeWithSelector(VLEILauncherFactoryBaseV2.UnsupportedQuoteDecimals.selector, uint8(6)));
        new VLEILauncherFactoryV2(
            address(portal), guardian, IVLEIRegistry(address(registry)), IPriceFeed(address(0)), address(six), 1 hours, admin
        );
        vm.expectRevert(VLEILauncherFactoryBaseV2.ZeroAddress.selector);
        new VLEILauncherFactoryV2(
            address(portal), guardian, IVLEIRegistry(address(registry)), IPriceFeed(address(0)), address(0), 1 hours, admin
        );
    }

    function test_factory_minTargetInQuoteUnits() public {
        uint256 fee = portal.SALT_LOCK_FEE();
        bytes memory data = abi.encode(_config(keccak256("low"), 1_499e18, CAP));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(VLEILauncherFactoryBaseV2.TargetBelowMinimum.selector, 1_499e18, 1_500e18));
        portal.newLauncher{value: fee}(address(factory), data);
        // exactly the floor is fine
        VLEIMintLauncherV2 l = _create(factory, _config(keccak256("ok"), 1_500e18, CAP));
        assertEq(l.targetRaise(), 1_500e18);
    }

    function test_launcher_initializedWithQuote() public {
        VLEIMintLauncherV2 l = _launcher();
        assertEq(l.quoteToken(), address(usdt));
        assertEq(address(l.priceFeed()), address(0));
        assertEq(l.factory(), address(factory));
        assertTrue(factory.isLauncher(address(l)));
        assertEq(l.status(), 0);
        assertTrue(l.creatorActive());
        assertEq(l.bnbUsdPrice(), 1e18, "ERC20 quote price is fixed at $1");
        assertEq(l.priceUpdatedAt(), block.timestamp);
        assertEq(l.remainingCapUsd(bob1), CAP);
        assertEq(l.maxContribution(bob1), CAP);
        assertTrue(LibString.contains(l.description(), LibString.toHexString(address(usdt))), "description quote");
    }

    // ── contribute() (no args) ──────────────────────────────────────────────

    function test_contribute_pullsTheAllowance() public {
        VLEIMintLauncherV2 l = _launcher();
        _approve(l, bob1, 400e18);
        assertEq(l.allowanceOf(bob1), 400e18);
        assertEq(l.quoteBalanceOf(bob1), 10_000e18);
        assertEq(l.previewContribute(bob1), 400e18);
        vm.prank(bob1);
        l.contribute();
        assertEq(l.contributionOf(bob1), 400e18);
        assertEq(l.raised(), 400e18);
        assertEq(usdt.balanceOf(address(l)), 400e18);
        assertEq(usdt.allowance(bob1, address(l)), 0);
        assertEq(l.investedUsd(leiB), 400e18);
        assertEq(l.remainingCapUsd(bob2), CAP - 400e18, "cap is per entity");
    }

    function test_contribute_clampsToEntityCap_acrossWallets() public {
        VLEIMintLauncherV2 l = _launcher();
        _approveAndContribute(l, bob1, 1_000e18);
        _approve(l, bob2, 5_000e18);
        assertEq(l.previewContribute(bob2), 200e18);
        vm.prank(bob2);
        l.contribute();
        assertEq(l.contributionOf(bob2), 200e18, "only what the entity cap allows");
        assertEq(usdt.allowance(bob2, address(l)), 4_800e18, "the rest of the allowance stays");
        vm.prank(bob2);
        vm.expectRevert(abi.encodeWithSelector(VLEILauncherBaseV2.EntityCapReached.selector, CAP, CAP));
        l.contribute();
    }

    function test_contribute_clampsToBalance_andTarget() public {
        VLEIMintLauncherV2 l = _create(factory, _config(keccak256("big"), TARGET, 100_000e18));
        address poor = makeAddr("poor");
        _register(poor, keccak256("POOR"), ECR);
        usdt.mint(poor, 300e18);
        _approve(l, poor, type(uint256).max);
        vm.prank(poor);
        l.contribute();
        assertEq(l.contributionOf(poor), 300e18, "clamped to balance");

        _approve(l, carol, type(uint256).max);
        vm.prank(carol);
        l.contribute();
        assertEq(l.contributionOf(carol), TARGET - 300e18, "clamped to what the target needs");
        assertTrue(l.launched());
        assertEq(usdt.balanceOf(carol), 10_000e18 - (TARGET - 300e18), "never pulled more than needed");
    }

    function test_contribute_errors() public {
        VLEIMintLauncherV2 l = _launcher();
        vm.prank(bob1);
        vm.expectRevert(VLEILauncherBaseV2.NoAllowance.selector);
        l.contribute();

        _approve(l, bob1, 100e18);
        vm.prank(bob1);
        vm.expectRevert(abi.encodeWithSelector(VLEILauncherBaseV2.UnexpectedNativeValue.selector, 1 ether));
        l.contribute{value: 1 ether}();

        address broke = makeAddr("broke");
        _register(broke, keccak256("BROKE"), ECR);
        _approve(l, broke, 100e18);
        vm.prank(broke);
        vm.expectRevert(VLEILauncherBaseV2.NoQuoteBalance.selector);
        l.contribute();

        _approve(l, outsider, 100e18);
        vm.prank(outsider);
        vm.expectRevert(VLEILauncherBaseV2.NotVerified.selector);
        l.contribute();

        vm.prank(outsider);
        vm.expectRevert(VLEILauncherBaseV2.NotVerified.selector);
        l.contributeAmount(100e18);
    }

    // ── contributeAmount(uint256) ───────────────────────────────────────────

    function test_contributeAmount_exact_capAndTarget() public {
        VLEIMintLauncherV2 l = _launcher();
        _approve(l, bob1, 5_000e18);
        vm.prank(bob1);
        l.contributeAmount(700e18);
        assertEq(l.contributionOf(bob1), 700e18);
        assertEq(usdt.allowance(bob1, address(l)), 4_300e18);

        vm.prank(bob1);
        vm.expectRevert(abi.encodeWithSelector(VLEILauncherBaseV2.CapExceeded.selector, 700e18, 600e18, CAP));
        l.contributeAmount(600e18);

        vm.prank(bob1);
        vm.expectRevert(VLEILauncherBaseV2.ZeroContribution.selector);
        l.contributeAmount(0);

        // without allowance the token reverts
        vm.prank(carol);
        vm.expectRevert();
        l.contributeAmount(100e18);

        // clamp to the target: 1,300 left, carol asks 5,000 with a 1,200 cap → cap error on the clamped 1,300
        _approve(l, carol, 5_000e18);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(VLEILauncherBaseV2.CapExceeded.selector, 0, 1_300e18, CAP));
        l.contributeAmount(5_000e18);
    }

    function test_contributeAmount_balanceDeltaCredit() public {
        VLEIMintLauncherV2 l = _launcher();
        usdt.setFeeBps(100); // 1% transfer fee
        _approve(l, bob1, 1_000e18);
        vm.prank(bob1);
        l.contributeAmount(1_000e18);
        assertEq(l.contributionOf(bob1), 990e18, "credited what arrived");
        assertEq(l.raised(), 990e18);
        assertEq(l.investedUsd(leiB), 990e18);
    }

    function test_contributeAmount_nativeLauncherReverts() public {
        VLEIMintLauncherV2 l = _create(bnbFactory, _config(keccak256("bnb"), 10 ether, 4_000e18));
        vm.prank(bob1);
        vm.expectRevert(VLEILauncherBaseV2.NativeQuote.selector);
        l.contributeAmount(1 ether);
    }

    // ── launch ──────────────────────────────────────────────────────────────

    function test_launch_approvesPortal_valueZero_quoteToken() public {
        VLEIMintLauncherV2 l = _launcher();
        _approveAndContribute(l, bob1, 1_000e18);
        _approveAndContribute(l, carol, 1_000e18);
        assertTrue(l.launched());
        assertEq(l.status(), 1);
        assertEq(portal.lastQuoteToken(), address(usdt));
        assertEq(portal.lastValue(), 0, "ERC20 launch sends no value");
        assertEq(portal.lastQuotePulled(), TARGET, "Portal pulled poolQuote");
        assertEq(usdt.balanceOf(address(l)), 0);
        assertEq(usdt.allowance(address(l), address(portal)), 0);
        assertEq(portal.lastCommissionReceiver(), address(0));
        IPortalTypes.FeeConfig memory div = portal.lastFee(2);
        assertEq(uint8(div.feeType), uint8(IPortalTypes.FeeSlotType.DIVIDEND));
        IPortalTypes.FeeConfigDividend memory d = abi.decode(div.configData, (IPortalTypes.FeeConfigDividend));
        assertEq(d.dividendToken, address(0), "dividends in the quote");

        // claims
        vm.prank(bob1);
        l.claim();
        assertEq(IERC20(l.token()).balanceOf(bob1), 250_000e18);
        assertEq(l.previewContribute(carol), 0);
    }

    function test_launch_rejectedByPortal_refundsInQuote_allowanceCleared() public {
        portal.setMinPoolQuote(TARGET + 1);
        VLEIMintLauncherV2 l = _launcher();
        _approveAndContribute(l, bob1, 1_000e18);
        _approveAndContribute(l, carol, 1_000e18);
        assertFalse(l.launched());
        assertTrue(l.launchFailed());
        assertEq(l.status(), 2);
        assertEq(usdt.balanceOf(address(l)), TARGET, "funds stayed");
        assertEq(usdt.allowance(address(l), address(portal)), 0, "approval cleared after the failure");
        vm.prank(carol);
        l.refund();
        assertEq(usdt.balanceOf(carol), 10_000e18);
        vm.prank(bob1);
        l.refund();
        assertEq(usdt.balanceOf(bob1), 10_000e18);
        assertEq(l.investedUsd(leiB), 0);
    }

    function test_launch_needsMinLaunchGas() public {
        VLEIMintLauncherV2 l = _launcher();
        _approveAndContribute(l, bob1, 1_000e18);
        _approve(l, carol, 1_000e18);
        vm.prank(carol);
        vm.expectPartialRevert(VLEILauncherBaseV2.InsufficientLaunchGas.selector);
        l.contribute{gas: 3_000_000}();
        assertEq(l.raised(), 1_000e18);
    }

    // ── refunds / withdraw / cancel in USDT ─────────────────────────────────

    function test_refundAfterDeadline_inQuote() public {
        VLEIMintLauncherV2 l = _launcher();
        _approveAndContribute(l, bob1, 500e18);
        vm.prank(bob1);
        vm.expectRevert(VLEILauncherBaseV2.RefundUnavailable.selector);
        l.refund();
        vm.warp(block.timestamp + 1 days);
        vm.prank(bob1);
        l.refund();
        assertEq(usdt.balanceOf(bob1), 10_000e18);
        assertEq(l.raised(), 0);
        assertEq(l.contributorLei(bob1), bytes32(0));
    }

    function test_withdrawAfterRevocation_inQuote() public {
        VLEIMintLauncherV2 l = _launcher();
        _approveAndContribute(l, bob1, 500e18);
        vm.prank(bob1);
        vm.expectRevert(VLEILauncherBaseV2.StillVerified.selector);
        l.withdrawContribution();
        vm.prank(admin);
        registry.revokeWallet(bob1, "revoked");
        vm.prank(bob1);
        l.withdrawContribution();
        assertEq(usdt.balanceOf(bob1), 10_000e18);
        assertEq(l.investedUsd(leiB), 0, "entity cap freed");
    }

    function test_cancelThenRefund_inQuote() public {
        VLEIMintLauncherV2 l = _launcher();
        _approveAndContribute(l, carol, 800e18);
        vm.expectRevert(VLEILauncherBaseV2.IssuerStillActive.selector);
        l.cancelIfCreatorRevoked();
        vm.prank(admin);
        registry.revokeWallet(alice, "officer revoked");
        _approve(l, bob1, 100e18);
        vm.prank(bob1);
        vm.expectRevert(VLEILauncherBaseV2.IssuerNotActive.selector);
        l.contribute();
        l.cancelIfCreatorRevoked();
        assertEq(l.status(), 3);
        vm.prank(carol);
        l.refund();
        assertEq(usdt.balanceOf(carol), 10_000e18);
    }

    // ── native v2 parity ────────────────────────────────────────────────────

    function test_native_v2_contributeExcessAndLaunch() public {
        VLEIMintLauncherV2 l = _create(bnbFactory, _config(keccak256("bnb"), 10 ether, 4_000e18));
        assertEq(l.quoteToken(), address(0));
        assertEq(l.bnbUsdPrice(), 600e18);
        assertEq(l.allowanceOf(bob1), type(uint256).max);
        assertEq(l.quoteBalanceOf(bob1), bob1.balance);
        vm.prank(bob1);
        l.contribute{value: 6 ether}();
        assertEq(l.investedUsd(leiB), 3_600e18);
        uint256 before = carol.balance;
        vm.prank(carol);
        l.contribute{value: 5 ether}();
        assertEq(before - carol.balance, 4 ether, "excess returned");
        assertTrue(l.launched());
        assertEq(portal.lastQuoteToken(), address(0));
        assertEq(portal.lastValue(), 10 ether);

        VLEIMintLauncherV2 l2 = _create(bnbFactory, _config(keccak256("bnb2"), 10 ether, 4_000e18));
        vm.prank(bob1);
        vm.expectRevert(VLEILauncherBaseV2.ZeroContribution.selector);
        l2.contribute();
    }
}
