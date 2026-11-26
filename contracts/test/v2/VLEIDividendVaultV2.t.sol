// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPortalTypes} from "src/flap/IPortal.sol";
import {Distribution} from "src/flap/Distribution.sol";
import {DirectLaunchVaultFactoryBase} from "src/flap/DirectLaunchVaultFactoryBase.sol";

import {VLEIRegistry} from "../../src/VLEIRegistry.sol";
import {VLEIMintConfig} from "../../src/VLEIMintLauncher.sol";
import {VLEIMintVaultLauncherV2} from "../../src/v2/VLEIMintVaultLauncherV2.sol";
import {VLEIVaultLauncherFactoryV2} from "../../src/v2/VLEIVaultLauncherFactoryV2.sol";
import {VLEIDividendVaultV2} from "../../src/v2/vault/VLEIDividendVaultV2.sol";
import {VLEIDividendVaultFactoryV2} from "../../src/v2/vault/VLEIDividendVaultFactoryV2.sol";
import {MockPriceFeed} from "../../src/mocks/MockPriceFeed.sol";
import {IVLEIRegistry} from "../../src/interfaces/IVLEIRegistry.sol";
import {IPriceFeed} from "../../src/interfaces/IPriceFeed.sol";
import {MockPortalV2} from "../mocks/MockPortalV2.sol";
import {MockQuoteToken} from "../mocks/MockQuoteToken.sol";
import {RegistryHelper} from "../utils/RegistryHelper.sol";

/// @notice Gated-yield v2 pair with an ERC20 quote (mock USDT): launch wiring, USDT revenue (ping and no-ping),
///         claims in USDT, eviction, held revenue; plus a native-BNB parity run.
contract VLEIDividendVaultV2Test is RegistryHelper {
    MockPortalV2 portal;
    MockQuoteToken usdt;
    MockPriceFeed feed;
    VLEIDividendVaultFactoryV2 vaultFactory;
    VLEIVaultLauncherFactoryV2 factory;

    address admin = makeAddr("admin");
    address guardian = makeAddr("guardian");
    address alice = makeAddr("aliceOfficer");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address trader = makeAddr("trader");
    address taxProc = makeAddr("taxProcessor");

    bytes32 issuerLei = keccak256("5493001KJTIIGC8Y1R12");
    bytes32 leiB = keccak256("984500E1B2C3D4E5F617");
    bytes32 leiC = keccak256("529900T8BM49AURSDO55");

    uint256 constant TARGET = 2_000e18;

    function setUp() public {
        vm.warp(1_750_000_000);
        registry = new VLEIRegistry(admin, vm.addr(verifierPk));
        portal = new MockPortalV2();
        usdt = new MockQuoteToken("Mock USDT", "USD", 18);
        feed = new MockPriceFeed(8, 600e8);
        (vaultFactory, factory) = _deployPair(address(usdt), IPriceFeed(address(0)));

        _register(alice, issuerLei, OFFICER);
        _register(bob, leiB, ECR);
        _register(carol, leiC, ECR);
        address[4] memory all = [alice, bob, carol, trader];
        for (uint256 i; i < all.length; ++i) {
            vm.deal(all[i], 100 ether);
            usdt.mint(all[i], 10_000e18);
        }
        usdt.mint(taxProc, 1_000_000e18);
        vm.prank(taxProc);
        usdt.approve(address(portal), type(uint256).max);
    }

    function _deployPair(address quote, IPriceFeed f)
        internal
        returns (VLEIDividendVaultFactoryV2 vf, VLEIVaultLauncherFactoryV2 lf)
    {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        vf = new VLEIDividendVaultFactoryV2(address(portal), guardian, predicted, quote);
        lf = new VLEIVaultLauncherFactoryV2(
            address(portal), guardian, IVLEIRegistry(address(registry)), f, quote, 1 hours, admin, address(vf)
        );
        assertEq(address(lf), predicted);
    }

    function _config(bytes32 salt, uint256 target) internal pure returns (VLEIMintConfig memory c) {
        c.name = "Siam T-Bill 2027";
        c.symbol = "STB27";
        c.meta = "ipfs://offering";
        c.salt = salt;
        c.targetRaise = target;
        c.saleDuration = 1 days;
        c.capUsdPerEntity = 100_000e18;
    }

    /// @dev USDT launch: bob 800, carol 1,200 → bob 200k tokens, carol 300k.
    function _launchUsdt() internal returns (VLEIMintVaultLauncherV2 l, VLEIDividendVaultV2 vault, IERC20 token) {
        uint256 fee = portal.SALT_LOCK_FEE();
        vm.prank(alice);
        l = VLEIMintVaultLauncherV2(
            payable(portal.newLauncher{value: fee}(address(factory), abi.encode(_config(keccak256("s"), TARGET))))
        );
        vm.startPrank(bob);
        usdt.approve(address(l), 800e18);
        l.contribute();
        vm.stopPrank();
        vm.startPrank(carol);
        usdt.approve(address(l), type(uint256).max);
        l.contribute();
        vm.stopPrank();
        assertTrue(l.launched());
        vault = VLEIDividendVaultV2(payable(l.vault()));
        token = IERC20(l.token());
        vm.prank(bob);
        l.claim();
        vm.prank(carol);
        l.claim();
    }

    function _stake(VLEIDividendVaultV2 v, IERC20 t, address who, uint256 amount) internal {
        vm.startPrank(who);
        t.approve(address(v), amount);
        v.stake(amount);
        vm.stopPrank();
    }

    function _pay(address token, uint256 amount, bool ping) internal {
        vm.prank(taxProc);
        portal.dispatchToVaultERC20(token, address(usdt), amount, ping);
    }

    // ── wiring ──────────────────────────────────────────────────────────────

    function test_pairing_quoteMustMatch() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        VLEIDividendVaultFactoryV2 nativeVf = new VLEIDividendVaultFactoryV2(address(portal), guardian, predicted, address(0));
        vm.expectRevert(
            abi.encodeWithSelector(VLEIVaultLauncherFactoryV2.VaultQuoteMismatch.selector, address(0), address(usdt))
        );
        new VLEIVaultLauncherFactoryV2(
            address(portal), guardian, IVLEIRegistry(address(registry)), IPriceFeed(address(0)), address(usdt), 1 hours, admin, address(nativeVf)
        );
    }

    function test_vaultFactory_quoteSupport() public view {
        assertTrue(vaultFactory.isQuoteTokenSupported(address(usdt)));
        assertFalse(vaultFactory.isQuoteTokenSupported(address(0)));
        assertEq(vaultFactory.quoteToken(), address(usdt));
        assertEq(abi.decode(vaultFactory.tokenCreationPolicies()[0].value, (address)), address(usdt));
    }

    function test_launch_createsUsdtVault() public {
        (VLEIMintVaultLauncherV2 l, VLEIDividendVaultV2 vault, IERC20 token) = _launchUsdt();
        assertEq(portal.lastQuoteToken(), address(usdt));
        assertEq(portal.lastValue(), 0);
        assertEq(usdt.allowance(address(l), address(portal)), 0);
        (address v, address vf) = portal.getLaunchVault(address(token));
        assertEq(v, address(vault));
        assertEq(vf, address(vaultFactory));
        assertEq(vault.quoteToken(), address(usdt));
        assertEq(vault.taxToken(), address(token));
        assertEq(vault.launcher(), address(l));
        assertEq(vault.version(), "v2.0.0");
        IPortalTypes.FeeConfig memory slot = portal.lastFee(2);
        assertEq(uint8(slot.feeType), uint8(IPortalTypes.FeeSlotType.VAULT));
    }

    // ── USDT revenue ────────────────────────────────────────────────────────

    function test_usdtRevenue_pingRecognized_claimInUsdt() public {
        (, VLEIDividendVaultV2 vault, IERC20 token) = _launchUsdt();
        _stake(vault, token, bob, 200_000e18);
        _stake(vault, token, carol, 200_000e18);

        _pay(address(token), 100e18, true);
        assertEq(vault.totalRevenue(), 100e18, "zero-value ping recognized the transfer");
        assertEq(vault.accountedBalance(), 100e18);
        assertEq(vault.claimable(bob), 50e18);

        uint256 b0 = usdt.balanceOf(bob);
        vm.prank(bob);
        assertEq(vault.claim(), 50e18);
        assertEq(usdt.balanceOf(bob) - b0, 50e18, "paid in USDT");
        assertEq(address(vault).balance, 0);
        vm.prank(bob);
        vm.expectRevert(VLEIDividendVaultV2.NothingToClaim.selector);
        vault.claim();

        // trader holds tokens but is unverified
        vm.prank(trader);
        vm.expectRevert(VLEIDividendVaultV2.NotVerified.selector);
        vault.stake(1e18);
        assertEq(vault.claimable(trader), 0);
    }

    function test_usdtRevenue_withoutPing_pendingThenSyncOnClaim() public {
        (, VLEIDividendVaultV2 vault, IERC20 token) = _launchUsdt();
        _stake(vault, token, bob, 200_000e18);
        _pay(address(token), 30e18, false);
        assertEq(vault.totalRevenue(), 0, "no wake yet");
        assertEq(vault.pendingRewards(bob), 30e18, "views include unsynced revenue");
        assertEq(vault.claimable(bob), 30e18);
        uint256 b0 = usdt.balanceOf(bob);
        vm.prank(bob);
        vault.claim(); // syncs first
        assertEq(usdt.balanceOf(bob) - b0, 30e18);

        _pay(address(token), 10e18, false);
        vault.sync(); // anyone
        assertEq(vault.totalRevenue(), 40e18);
        vault.sync(); // idempotent
        (bool ok,) = address(vault).call(""); // spurious ping
        assertTrue(ok);
        assertEq(vault.totalRevenue(), 40e18);
    }

    function test_usdtRevenue_stakeTriggersSync_lateStakerGetsNoPast() public {
        (, VLEIDividendVaultV2 vault, IERC20 token) = _launchUsdt();
        _stake(vault, token, bob, 200_000e18);
        _pay(address(token), 60e18, false);
        _stake(vault, token, carol, 200_000e18); // syncs the 60 to bob before carol joins
        assertEq(vault.totalRevenue(), 60e18);
        assertEq(vault.pendingRewards(bob), 60e18);
        assertEq(vault.pendingRewards(carol), 0);
    }

    function test_usdtRevenue_heldUntilMinStake() public {
        (, VLEIDividendVaultV2 vault, IERC20 token) = _launchUsdt();
        _pay(address(token), 50e18, true);
        assertEq(vault.undistributed(), 50e18);
        _stake(vault, token, bob, 1e18);
        assertEq(vault.claimable(bob), 0, "a 1-token staker cannot sweep held revenue");
        _stake(vault, token, carol, 10_000e18);
        assertApproxEqAbs(vault.pendingRewards(carol) + vault.pendingRewards(bob), 50e18, 2);
    }

    function test_usdtRevenue_revokedCannotClaim_evictRedistributes() public {
        (, VLEIDividendVaultV2 vault, IERC20 token) = _launchUsdt();
        _stake(vault, token, bob, 200_000e18);
        _stake(vault, token, carol, 200_000e18);
        _pay(address(token), 100e18, true);

        vm.prank(admin);
        registry.revokeWallet(carol, "revoked");
        vm.prank(carol);
        vm.expectRevert(VLEIDividendVaultV2.NotVerified.selector);
        vault.claim();
        assertEq(vault.claimable(carol), 0);

        vm.expectRevert(abi.encodeWithSelector(VLEIDividendVaultV2.NotEvictable.selector, bob));
        vault.evict(bob);
        uint256 c0 = token.balanceOf(carol);
        vault.evict(carol);
        assertEq(token.balanceOf(carol) - c0, 200_000e18, "principal back");
        assertEq(vault.totalForfeited(), 50e18);

        uint256 b0 = usdt.balanceOf(bob);
        vm.prank(bob);
        vault.claim();
        assertApproxEqAbs(usdt.balanceOf(bob) - b0, 100e18, 2, "bob gets carol's forfeited share");
        assertLe(usdt.balanceOf(address(vault)), 2);
        assertEq(vault.totalClaimed() + vault.accountedBalance(), 100e18);
    }

    function test_usdtVault_ignoresNativeValue() public {
        (, VLEIDividendVaultV2 vault, IERC20 token) = _launchUsdt();
        _stake(vault, token, bob, 200_000e18);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertTrue(ok, "receive never reverts");
        assertEq(vault.totalRevenue(), 0, "BNB is not revenue of a USDT vault");
    }

    // ── native parity ───────────────────────────────────────────────────────

    function test_native_v2_pair_bnbRevenue() public {
        (VLEIDividendVaultFactoryV2 nvf, VLEIVaultLauncherFactoryV2 nlf) =
            _deployPair(address(0), IPriceFeed(address(feed)));
        uint256 fee = portal.SALT_LOCK_FEE();
        vm.prank(alice);
        VLEIMintVaultLauncherV2 l = VLEIMintVaultLauncherV2(
            payable(portal.newLauncher{value: fee}(address(nlf), abi.encode(_config(keccak256("n"), 10 ether))))
        );
        vm.prank(bob);
        l.contribute{value: 10 ether}();
        assertTrue(l.launched());
        VLEIDividendVaultV2 vault = VLEIDividendVaultV2(payable(l.vault()));
        assertEq(vault.quoteToken(), address(0));
        assertTrue(nvf.isQuoteTokenSupported(address(0)));
        IERC20 token = IERC20(l.token());
        vm.prank(bob);
        l.claim();
        _stake(vault, token, bob, 500_000e18);
        portal.dispatchToVault{value: 1 ether}(address(token));
        assertEq(vault.totalRevenue(), 1 ether);
        uint256 b0 = bob.balance;
        vm.prank(bob);
        vault.claim();
        assertEq(bob.balance - b0, 1 ether);
    }

    function test_newVault_rejectsWrongQuote_andNotLaunching() public {
        uint256 fee = portal.SALT_LOCK_FEE();
        vm.prank(alice);
        address l = portal.newLauncher{value: fee}(address(factory), abi.encode(_config(keccak256("q"), TARGET)));
        IPortalTypes.FeeConfig[] memory fees = new IPortalTypes.FeeConfig[](2);
        fees[0] = IPortalTypes.FeeConfig({
            feeType: IPortalTypes.FeeSlotType.VAULT,
            bps: 7500,
            configData: abi.encode(
                IPortalTypes.FeeConfigVault({vaultFactory: address(vaultFactory), vaultData: abi.encode(l)})
            )
        });
        fees[1] = IPortalTypes.FeeConfig({feeType: IPortalTypes.FeeSlotType.DEFLATION, bps: 2500, configData: ""});
        IPortalTypes.CreateTaxTokenParams memory p;
        p.totalSupply = 1_000_000 ether;
        p.feeConfigs = fees;
        Distribution memory d;

        vm.startPrank(address(portal));
        p.quoteToken = address(0); // native launch into a USDT vault factory
        vm.expectRevert(abi.encodeWithSelector(DirectLaunchVaultFactoryBase.UnsupportedQuoteToken.selector, address(0)));
        vaultFactory.newVault(address(0x7777), l, 0, abi.encode(p, d));
        p.quoteToken = address(usdt); // right quote, but the launcher is not mid-launch
        vm.expectRevert(abi.encodeWithSelector(VLEIDividendVaultFactoryV2.LauncherNotLaunching.selector, l));
        vaultFactory.newVault(address(0x7777), l, 0, abi.encode(p, d));
        vm.stopPrank();
    }
}
