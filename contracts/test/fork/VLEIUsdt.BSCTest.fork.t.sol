// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IPortal} from "src/flap/IPortal.sol";
import {LaunchVaultAddresses} from "src/flap/LaunchVaultAddresses.sol";

import {VLEIRegistry} from "../../src/VLEIRegistry.sol";
import {VLEIMintConfig} from "../../src/VLEIMintLauncher.sol";
import {VLEILauncherBaseV2} from "../../src/v2/VLEILauncherBaseV2.sol";
import {VLEILauncherFactoryV2} from "../../src/v2/VLEILauncherFactoryV2.sol";
import {VLEIMintLauncherV2} from "../../src/v2/VLEIMintLauncherV2.sol";
import {VLEIVaultLauncherFactoryV2} from "../../src/v2/VLEIVaultLauncherFactoryV2.sol";
import {VLEIMintVaultLauncherV2} from "../../src/v2/VLEIMintVaultLauncherV2.sol";
import {VLEIDividendVaultV2} from "../../src/v2/vault/VLEIDividendVaultV2.sol";
import {VLEIDividendVaultFactoryV2} from "../../src/v2/vault/VLEIDividendVaultFactoryV2.sol";
import {IVLEIRegistry} from "../../src/interfaces/IVLEIRegistry.sol";
import {IPriceFeed} from "../../src/interfaces/IPriceFeed.sol";
import {RegistryHelper} from "../utils/RegistryHelper.sol";

interface IMockUsdt {
    function mint(address to, uint256 amount) external;
}

interface IUsdtRouter {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IUsdtTaxToken {
    function taxProcessor() external view returns (address);
}

interface IUsdtTaxProcessor {
    function dispatch() external;
    function feeQuoteBalance() external view returns (uint256);
    function marketQuoteBalance() external view returns (uint256);
    function pendingDividendQuoteTokenBalance() external view returns (uint256);
    function lpQuoteBalance() external view returns (uint256);
}

interface IPortalFloors {
    struct GraduationFloorParams {
        address quoteToken;
        uint256 quotePriceUsd;
        uint256 poolQuote;
        uint256 poolToken;
        uint256 totalSupply;
        address vaultFactory;
    }

    struct GraduationFloorResultV2 {
        bool meetsFloor;
        uint256 floorUsdWad;
        uint256 quoteUsdWad;
        uint16 multiplierBps;
        bool meetsCreateFloor;
        uint256 createFloorUsdWad;
    }

    function launchQuoteConfig(uint8 kind, address quoteToken) external view returns (bool, uint256);
    function graduationFloorV2ForLauncher(GraduationFloorParams calldata p, address launcher)
        external
        view
        returns (GraduationFloorResultV2 memory);
}

/// @notice v2 launchers with Flap's REAL mock USDT (0x190C…0157) on the LIVE BNB Testnet Portal, with factories that
///         Flap has NOT enabled (Portal v1.2.0 does not require it). Full journey: verified creator → launcher →
///         unverified contribute reverts → verified contributors approve + no-arg contribute() to 1,500 USDT → launch
///         (token ends in 7777) → claim → DEX trades produce tax → USDT reaches the vault → verified staker claims USDT
///         → revoked staker cannot. Needs `BSC_TESTNET_RPC_URL` or `BSC_TESTNET_RPC`; skipped without.
contract VLEIUsdtBSCTestForkTest is RegistryHelper {
    address constant PORTAL = 0x000042108465206185A077Edc3F3fd2b49060000;
    address constant TOKEN_IMPL = 0x7777c57ff7dc441c1715b2e36fa581c48B782222;
    address constant GUARDIAN = 0x00004d58290854c5E9880F4b5B1993c6Ad8b0000;
    address constant USDT = 0x190C989D5665a0e404B444b53CAE9AbCfb600157;
    address constant ROUTER = 0xc9D63ddCB9549578057EAB6A83a543DdFEE2b8c3;

    IPortal portal = IPortal(PORTAL);
    IERC20 usdt = IERC20(USDT);
    VLEIDividendVaultFactoryV2 vaultFactory;
    VLEIVaultLauncherFactoryV2 vaultLauncherFactory;
    VLEILauncherFactoryV2 plainFactory;
    address regAdmin = address(uint160(0xC0DE00AD));

    address alice = address(uint160(0xC0DE0002)); //    OOR officer: creates the launch
    address bob = address(uint160(0xC0DE0003)); //      verified entity B
    address carol = address(uint160(0xC0DE0005)); //    verified entity C (revoked later)
    address trader = address(uint160(0xC0DE0004)); //   unverified, trades on the DEX
    address outsider = address(uint160(0xC0DE0006)); // never verified

    bytes32 issuerLei = keccak256("5493001KJTIIGC8Y1R12");
    bytes32 leiB = keccak256("984500E1B2C3D4E5F617");
    bytes32 leiC = keccak256("529900T8BM49AURSDO55");

    function setUp() public {
        string memory rpc = vm.envOr("BSC_TESTNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) rpc = vm.envOr("BSC_TESTNET_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        require(block.chainid == 97, "not BNB Testnet");
        assertEq(LaunchVaultAddresses.hub(), PORTAL);
        (bool enabled, uint256 price) = IPortalFloors(PORTAL).launchQuoteConfig(0, USDT);
        assertTrue(enabled, "USDT enabled as a Pool Launch quote");
        assertEq(price, 1e18, "USDT = $1");

        registry = new VLEIRegistry(regAdmin, vm.addr(verifierPk));
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        vaultFactory = new VLEIDividendVaultFactoryV2(PORTAL, GUARDIAN, predicted, USDT);
        vaultLauncherFactory = new VLEIVaultLauncherFactoryV2(
            PORTAL, GUARDIAN, IVLEIRegistry(address(registry)), IPriceFeed(address(0)), USDT, 1 days, regAdmin, address(vaultFactory)
        );
        assertEq(address(vaultLauncherFactory), predicted);
        plainFactory = new VLEILauncherFactoryV2(
            PORTAL, GUARDIAN, IVLEIRegistry(address(registry)), IPriceFeed(address(0)), USDT, 1 days, regAdmin
        );
        // NOTE: no setLauncherFactoryMultiplier / setVaultFactoryMultiplier: the factories are NOT enabled by Flap.

        _register(alice, issuerLei, OFFICER);
        _register(bob, leiB, ECR);
        _register(carol, leiC, ECR);
        address[5] memory all = [alice, bob, carol, trader, outsider];
        for (uint256 i; i < all.length; ++i) {
            require(all[i].code.length == 0, "code");
            vm.deal(all[i], 10 ether);
            IMockUsdt(USDT).mint(all[i], 20_000e18); // anyone can mint Flap's mock USDT
        }
    }

    function _mineSalt(bytes32 seed) internal pure returns (bytes32 salt) {
        for (uint256 i = 1;; ++i) {
            assembly ("memory-safe") {
                mstore(0x00, seed)
                mstore(0x20, i)
                salt := keccak256(0x00, 0x40)
            }
            if (uint16(uint160(Clones.predictDeterministicAddress(TOKEN_IMPL, salt, PORTAL))) == 0x7777) return salt;
        }
    }

    function _config(bytes32 seed, uint256 target) internal pure returns (VLEIMintConfig memory c) {
        c.name = "Siam T-Bill 2027";
        c.symbol = "STB27";
        c.meta = "bafkreig4y5nwb4izyilbbmiydumvkld446d4k7j4ohg3x3q2lfel3fo4yq";
        c.salt = _mineSalt(seed);
        c.targetRaise = target;
        c.saleDuration = 1 days;
        c.capUsdPerEntity = 1_000e18; // 1,000 USDT per entity
    }

    function _floor(uint256 poolQuote, address launcher) internal view returns (IPortalFloors.GraduationFloorResultV2 memory) {
        return IPortalFloors(PORTAL).graduationFloorV2ForLauncher(
            IPortalFloors.GraduationFloorParams({
                quoteToken: USDT,
                quotePriceUsd: 1e18,
                poolQuote: poolQuote,
                poolToken: 500_000 ether,
                totalSupply: 1_000_000 ether,
                vaultFactory: address(0)
            }),
            launcher
        );
    }

    function _swap(address from, address to, uint256 amountIn) internal {
        IERC20(from).approve(ROUTER, amountIn);
        address[] memory path = new address[](2);
        path[0] = from;
        path[1] = to;
        IUsdtRouter(ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountIn, 0, path, trader, block.timestamp + 600
        );
    }

    function _taxLiquidated(address proc) internal view returns (bool) {
        IUsdtTaxProcessor t = IUsdtTaxProcessor(proc);
        return t.feeQuoteBalance() > 0 || t.marketQuoteBalance() > 0 || t.pendingDividendQuoteTokenBalance() > 0
            || t.lpQuoteBalance() > 0;
    }

    /// @dev Unverified trader buys and sells with USDT until the tax is liquidated, then dispatches it.
    function _generateTaxAndDispatch(address token) internal {
        vm.warp(block.timestamp + 601);
        address proc = IUsdtTaxToken(token).taxProcessor();
        vm.startPrank(trader);
        _swap(USDT, token, 4_000e18);
        for (uint256 i; i < 80; ++i) {
            if (_taxLiquidated(proc)) break;
            uint256 sellAmt = IERC20(token).balanceOf(trader) * 30 / 100;
            if (sellAmt == 0) break;
            uint256 before_ = usdt.balanceOf(trader);
            _swap(token, USDT, sellAmt);
            uint256 proceeds = usdt.balanceOf(trader) - before_;
            if (proceeds > 0) _swap(USDT, token, proceeds * 90 / 100);
        }
        vm.stopPrank();
        assertTrue(_taxLiquidated(proc), "tax never liquidated");
        IUsdtTaxProcessor(proc).dispatch();
    }

    function _approveContribute(address l, address who, uint256 allowance) internal {
        vm.startPrank(who);
        usdt.approve(l, allowance);
        VLEILauncherBaseV2(payable(l)).contribute();
        vm.stopPrank();
    }

    function test_usdt_gatedYield_fullJourney_unenabledFactories() public {
        uint256 fee = portal.SALT_LOCK_FEE();
        // Unverified creator cannot create.
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("CreatorNotAuthorized(address)")), outsider));
        portal.newLauncher{value: fee}(address(vaultLauncherFactory), abi.encode(_config("usdt-gy", 1_500e18)));

        vm.prank(alice);
        VLEIMintVaultLauncherV2 l = VLEIMintVaultLauncherV2(
            payable(portal.newLauncher{value: fee}(address(vaultLauncherFactory), abi.encode(_config("usdt-gy", 1_500e18))))
        );
        assertEq(portal.getLauncher(address(l)).launcherFactory, address(vaultLauncherFactory));
        assertEq(l.quoteToken(), USDT);
        assertEq(l.bnbUsdPrice(), 1e18);
        IPortalFloors.GraduationFloorResultV2 memory f = _floor(1_500e18, address(l));
        emit log_named_uint("creation floor (USD wad)", f.createFloorUsdWad);
        emit log_named_uint("graduation floor (USD wad)", f.floorUsdWad);
        emit log_named_uint("multiplier bps", f.multiplierBps);
        assertTrue(f.meetsCreateFloor);

        // Unverified wallet with an allowance cannot contribute.
        vm.startPrank(outsider);
        usdt.approve(address(l), 1_000e18);
        vm.expectRevert(VLEILauncherBaseV2.NotVerified.selector);
        l.contribute();
        vm.stopPrank();

        // Verified contributors: approve + no-arg contribute().
        _approveContribute(address(l), bob, 600e18);
        assertEq(l.contributionOf(bob), 600e18);
        uint256 carol0 = usdt.balanceOf(carol);
        vm.recordLogs();
        uint256 g0 = gasleft();
        _approveContribute(address(l), carol, type(uint256).max); // pulls exactly the 900 still needed
        emit log_named_uint("gas: final contribute() incl. launch", g0 - gasleft());
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(l) && logs[i].topics[0] == VLEILauncherBaseV2.LaunchFailed.selector) {
                emit log_named_bytes("LaunchFailed", abi.decode(logs[i].data, (bytes)));
            }
        }
        assertTrue(l.launched(), "launched on the live Portal with USDT");
        assertEq(carol0 - usdt.balanceOf(carol), 900e18);
        assertEq(usdt.balanceOf(address(l)), 0, "the Portal pulled the whole raise");
        assertEq(usdt.allowance(address(l), PORTAL), 0);
        address tokenAddr = l.token();
        IERC20 token = IERC20(tokenAddr);
        assertEq(uint16(uint160(tokenAddr)), 0x7777, "vanity suffix");
        emit log_named_address("token", tokenAddr);

        (address vaultAddr, address vf) = portal.getLaunchVault(tokenAddr);
        assertEq(vf, address(vaultFactory), "vault from the (unenabled) paired factory");
        assertEq(vaultAddr, l.vault());
        VLEIDividendVaultV2 vault = VLEIDividendVaultV2(payable(vaultAddr));
        assertEq(vault.quoteToken(), USDT);
        emit log_named_address("vault", vaultAddr);

        // Claims: bob 200k, carol 300k.
        vm.prank(bob);
        l.claim();
        vm.prank(carol);
        l.claim();
        uint256 stakeAmt = token.balanceOf(bob);
        assertEq(stakeAmt, 200_000 ether);
        vm.startPrank(bob);
        token.approve(vaultAddr, stakeAmt);
        vault.stake(stakeAmt);
        vm.stopPrank();
        vm.startPrank(carol);
        token.approve(vaultAddr, stakeAmt);
        vault.stake(stakeAmt);
        vm.stopPrank();
        assertEq(vault.totalStaked(), 2 * stakeAmt);

        // DEX trades by an unverified trader; the TaxProcessor pays the VAULT slot in USDT.
        uint256 vaultUsdt0 = usdt.balanceOf(vaultAddr);
        _generateTaxAndDispatch(tokenAddr);
        uint256 arrived = usdt.balanceOf(vaultAddr) - vaultUsdt0;
        emit log_named_uint("USDT arrived at the vault (wei)", arrived);
        emit log_named_uint("recognized by the dispatch ping (wei)", vault.totalRevenue());
        assertGt(arrived, 0, "the VAULT slot paid USDT");
        assertEq(vaultAddr.balance, 0, "no BNB in a USDT vault");
        vault.sync();
        uint256 revenue = vault.totalRevenue();
        assertEq(revenue, arrived, "all USDT recognized");

        // The unverified trader cannot stake.
        uint256 traderTokens = token.balanceOf(trader);
        vm.startPrank(trader);
        token.approve(vaultAddr, traderTokens);
        vm.expectRevert(VLEIDividendVaultV2.NotVerified.selector);
        vault.stake(traderTokens);
        vm.stopPrank();

        // carol revoked: cannot claim; evicted by bob, her half goes to bob.
        vm.prank(regAdmin);
        registry.revokeWallet(carol, "ECR revoked");
        vm.prank(carol);
        vm.expectRevert(VLEIDividendVaultV2.NotVerified.selector);
        vault.claim();
        vm.prank(bob);
        vault.evict(carol);
        assertEq(token.balanceOf(carol), 300_000 ether, "carol's principal returned");

        uint256 b0 = usdt.balanceOf(bob);
        vm.prank(bob);
        vault.claim();
        assertApproxEqAbs(usdt.balanceOf(bob) - b0, revenue, 3, "bob receives the revenue in USDT");
        assertEq(vault.totalClaimed() + vault.accountedBalance(), revenue);
    }

    /// The plain v2 launcher (DIVIDEND slot paid in USDT) at 3,000 USDT: meets the graduation floor.
    function test_usdt_plainLauncher_graduates() public {
        uint256 fee = portal.SALT_LOCK_FEE();
        VLEIMintConfig memory c = _config("usdt-plain", 3_000e18);
        c.capUsdPerEntity = 2_000e18;
        vm.prank(alice);
        VLEIMintLauncherV2 l =
            VLEIMintLauncherV2(payable(portal.newLauncher{value: fee}(address(plainFactory), abi.encode(c))));
        IPortalFloors.GraduationFloorResultV2 memory f = _floor(3_000e18, address(l));
        assertTrue(f.meetsFloor, "3,000 USDT meets the graduation floor");

        vm.prank(bob);
        usdt.approve(address(l), 1_500e18);
        vm.prank(bob);
        l.contributeAmount(1_500e18); // KYB-portal path
        vm.recordLogs();
        _approveContribute(address(l), carol, 5_000e18);
        assertTrue(l.launched());
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool graduated;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == PORTAL && logs[i].topics[0] == keccak256("FlapTokenGraduated(address)")) {
                graduated = true;
            }
        }
        emit log_named_string("FlapTokenGraduated emitted", graduated ? "yes" : "no");
        assertTrue(graduated);
        assertEq(uint16(uint160(l.token())), 0x7777);
        vm.prank(carol);
        l.claim();
        assertEq(IERC20(l.token()).balanceOf(carol), 250_000 ether);
    }

    /// Below the Portal's creation floor (owner lowered our minimum): the Portal rejects; refunds pay USDT back.
    function test_usdt_portalRejection_refundsInUsdt() public {
        vm.prank(regAdmin);
        plainFactory.setMinTargetUsd(0);
        uint256 fee = portal.SALT_LOCK_FEE();
        VLEIMintConfig memory c = _config("usdt-low", 100e18);
        vm.prank(alice);
        VLEIMintLauncherV2 l =
            VLEIMintLauncherV2(payable(portal.newLauncher{value: fee}(address(plainFactory), abi.encode(c))));
        uint256 b0 = usdt.balanceOf(bob);
        _approveContribute(address(l), bob, 100e18);
        assertTrue(l.launchFailed());
        assertEq(l.status(), 2);
        assertEq(usdt.allowance(address(l), PORTAL), 0);
        vm.prank(bob);
        l.refund();
        assertEq(usdt.balanceOf(bob), b0);
    }
}
