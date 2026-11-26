// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IPortal} from "src/flap/IPortal.sol";
import {LaunchVaultAddresses} from "src/flap/LaunchVaultAddresses.sol";

import {VLEIRegistry} from "../../src/VLEIRegistry.sol";
import {VLEIMintConfig} from "../../src/VLEIMintLauncher.sol";
import {VLEIMintVaultLauncher} from "../../src/VLEIMintVaultLauncher.sol";
import {VLEIVaultLauncherFactory} from "../../src/VLEIVaultLauncherFactory.sol";
import {VLEIDividendVault} from "../../src/vault/VLEIDividendVault.sol";
import {VLEIDividendVaultFactory} from "../../src/vault/VLEIDividendVaultFactory.sol";
import {MockPriceFeed} from "../../src/mocks/MockPriceFeed.sol";
import {IVLEIRegistry} from "../../src/interfaces/IVLEIRegistry.sol";
import {IPriceFeed} from "../../src/interfaces/IPriceFeed.sol";
import {RegistryHelper} from "../utils/RegistryHelper.sol";

interface IProxyAdminLike2 {
    function owner() external view returns (address);
}

interface IRouterLike {
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable;
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface ITaxTokenLike {
    function taxProcessor() external view returns (address);
}

interface ITaxProcessorLike {
    function dispatch() external;
    function feeQuoteBalance() external view returns (uint256);
    function marketQuoteBalance() external view returns (uint256);
    function pendingDividendQuoteTokenBalance() external view returns (uint256);
    function lpQuoteBalance() external view returns (uint256);
}

/// @notice Gated yield on the LIVE BNB Testnet Portal: a `VLEIMintVaultLauncher` launch whose VAULT slot creates a
///         `VLEIDividendVault`; real DEX trades by an unverified trader generate tax; the TaxProcessor pays the vault;
///         a verified staker claims; a revoked staker cannot, and its share is redistributed on eviction.
///         Needs `BSC_TESTNET_RPC_URL` or `BSC_TESTNET_RPC`; skipped without.
contract VLEIDividendVaultBSCTestForkTest is RegistryHelper {
    address constant PORTAL = 0x000042108465206185A077Edc3F3fd2b49060000;
    address constant PORTAL_PROXY_ADMIN = 0x0000Ed588dfc01749C20bA69b5f8c77d706E0000;
    address constant TOKEN_IMPL = 0x7777c57ff7dc441c1715b2e36fa581c48B782222;
    address constant GUARDIAN = 0x00004d58290854c5E9880F4b5B1993c6Ad8b0000;
    address constant WBNB = 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd;
    address constant ROUTER = 0xc9D63ddCB9549578057EAB6A83a543DdFEE2b8c3;

    IPortal portal = IPortal(PORTAL);
    address portalAdmin;
    VLEIDividendVaultFactory vaultFactory;
    VLEIVaultLauncherFactory factory;
    MockPriceFeed feed;
    address regAdmin = address(uint160(0xC0DE00AD));

    address alice = address(uint160(0xC0DE0002)); //  OOR officer: creates the launch
    address bob = address(uint160(0xC0DE0003)); //    verified entity B
    address carol = address(uint160(0xC0DE0005)); // verified entity C (revoked later)
    address trader = address(uint160(0xC0DE0004)); // unverified, trades on the DEX

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
        portalAdmin = IProxyAdminLike2(PORTAL_PROXY_ADMIN).owner();

        registry = new VLEIRegistry(regAdmin, vm.addr(verifierPk));
        feed = new MockPriceFeed(8, 600e8);
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        vaultFactory = new VLEIDividendVaultFactory(PORTAL, GUARDIAN, predicted);
        factory = new VLEIVaultLauncherFactory(
            PORTAL, GUARDIAN, IVLEIRegistry(address(registry)), IPriceFeed(address(feed)), 1 days, regAdmin,
            address(vaultFactory)
        );
        assertEq(address(factory), predicted);

        _register(alice, issuerLei, OFFICER);
        _register(bob, leiB, ECR);
        _register(carol, leiC, ECR);
        vm.deal(alice, 10 ether);
        vm.deal(bob, 30 ether);
        vm.deal(carol, 30 ether);
        vm.deal(trader, 1000 ether);
        require(alice.code.length + bob.code.length + carol.code.length + trader.code.length == 0, "code");

        // Flap opens both factories (Portal admin). Start from a paused Portal, as Flap's ForkBase does.
        vm.startPrank(portalAdmin);
        portal.setCreationPaused(true);
        portal.setLauncherFactoryMultiplier(address(factory), 10_000, true);
        portal.setVaultFactoryMultiplier(address(vaultFactory), 10_000, true);
        vm.stopPrank();
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

    function _config(bytes32 seed) internal pure returns (VLEIMintConfig memory c) {
        c.name = "Siam T-Bill 2027";
        c.symbol = "STB27";
        c.meta = "bafkreig4y5nwb4izyilbbmiydumvkld446d4k7j4ohg3x3q2lfel3fo4yq";
        c.salt = _mineSalt(seed);
        c.targetRaise = 10 ether;
        c.saleDuration = 1 days;
        c.capUsdPerEntity = 5_000e18;
    }

    function _buy(address token, uint256 bnb) internal {
        address[] memory path = new address[](2);
        path[0] = WBNB;
        path[1] = token;
        IRouterLike(ROUTER).swapExactETHForTokensSupportingFeeOnTransferTokens{value: bnb}(
            0, path, trader, block.timestamp + 600
        );
    }

    function _sell(address token, uint256 amount) internal {
        IERC20(token).approve(ROUTER, amount);
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = WBNB;
        IRouterLike(ROUTER).swapExactTokensForETHSupportingFeeOnTransferTokens(
            amount, 0, path, trader, block.timestamp + 600
        );
    }

    function _taxLiquidated(address proc) internal view returns (bool) {
        ITaxProcessorLike t = ITaxProcessorLike(proc);
        return t.feeQuoteBalance() > 0 || t.marketQuoteBalance() > 0 || t.pendingDividendQuoteTokenBalance() > 0
            || t.lpQuoteBalance() > 0;
    }

    /// @dev Same loop as Flap's ForkBase: trade until the tax is liquidated, then dispatch it to the fee slots.
    function _generateTaxAndDispatch(address token) internal {
        vm.warp(block.timestamp + 601);
        address proc = ITaxTokenLike(token).taxProcessor();
        vm.startPrank(trader);
        _buy(token, 40 ether);
        for (uint256 i; i < 80; ++i) {
            if (_taxLiquidated(proc)) break;
            uint256 sellAmt = IERC20(token).balanceOf(trader) * 30 / 100;
            if (sellAmt == 0) break;
            uint256 before_ = trader.balance;
            _sell(token, sellAmt);
            uint256 proceeds = trader.balance - before_;
            if (proceeds > 0) _buy(token, proceeds * 90 / 100);
        }
        vm.stopPrank();
        assertTrue(_taxLiquidated(proc), "tax never liquidated");
        ITaxProcessorLike(proc).dispatch();
    }

    function _stake(address who, uint256 amount, VLEIDividendVault vault, IERC20 token) internal {
        vm.startPrank(who);
        token.approve(address(vault), amount);
        vault.stake(amount);
        vm.stopPrank();
    }

    function test_gatedYield_fullJourneyOnLivePortal() public {
        uint256 fee = portal.SALT_LOCK_FEE();
        vm.prank(alice);
        VLEIMintVaultLauncher l = VLEIMintVaultLauncher(
            payable(portal.newLauncher{value: fee}(address(factory), abi.encode(_config("gated-yield"))))
        );
        assertEq(portal.getLauncher(address(l)).launcherFactory, address(factory));

        vm.prank(bob);
        l.contribute{value: 4 ether}();
        vm.prank(carol);
        l.contribute{value: 6 ether}();
        assertTrue(l.launched(), "launched on the live Portal");
        address tokenAddr = l.token();
        IERC20 token = IERC20(tokenAddr);
        assertEq(uint16(uint160(tokenAddr)), 0x7777);

        // The Portal created our vault from the VAULT slot and recorded it for the token.
        (address vaultAddr, address vf) = portal.getLaunchVault(tokenAddr);
        assertEq(vf, address(vaultFactory), "vault came from the paired factory");
        assertEq(vaultAddr, l.vault(), "launcher recorded the same vault");
        VLEIDividendVault vault = VLEIDividendVault(payable(vaultAddr));
        assertEq(vault.taxToken(), tokenAddr);
        assertEq(vault.launcher(), address(l));
        emit log_named_address("token", tokenAddr);
        emit log_named_address("vault", vaultAddr);
        emit log_string(vault.description());

        // Verified contributors claim their tokens and stake them (a wallet -> vault transfer is not taxed).
        vm.prank(bob);
        l.claim();
        vm.prank(carol);
        l.claim();
        uint256 bobTokens = token.balanceOf(bob); // 200k
        uint256 carolTokens = token.balanceOf(carol); // 300k
        _stake(bob, bobTokens, vault, token);
        _stake(carol, bobTokens, vault, token); // equal stakes: 200k each
        assertEq(vault.stakedOf(bob), bobTokens, "staking is not taxed");
        assertEq(vault.totalStaked(), 2 * bobTokens);

        // Unverified trader generates tax with real DEX trades; the TaxProcessor pays the VAULT slot.
        _generateTaxAndDispatch(tokenAddr);
        uint256 revenue = vault.totalRevenue();
        emit log_named_uint("vault revenue (wei)", revenue);
        assertGt(revenue, 0, "the VAULT slot paid the vault");
        assertEq(vault.accountedBalance(), vaultAddr.balance, "receive() recognized it during dispatch");

        // The unverified trader holds tokens but cannot stake or earn.
        uint256 traderTokens = token.balanceOf(trader);
        assertGt(traderTokens, 1 ether);
        vm.startPrank(trader);
        token.approve(vaultAddr, traderTokens);
        vm.expectRevert(VLEIDividendVault.NotVerified.selector);
        vault.stake(traderTokens);
        vm.stopPrank();
        assertEq(vault.claimable(trader), 0);

        // carol's wallet is revoked: she cannot claim.
        vm.prank(regAdmin);
        registry.revokeWallet(carol, "ECR revoked");
        assertApproxEqAbs(vault.pendingRewards(carol), revenue / 2, 2);
        vm.prank(carol);
        vm.expectRevert(VLEIDividendVault.NotVerified.selector);
        vault.claim();

        // bob evicts her: her tokens come back, her half is forfeited to bob.
        vm.prank(bob);
        vault.evict(carol);
        assertEq(token.balanceOf(carol), carolTokens, "carol's principal returned");
        assertApproxEqAbs(vault.totalForfeited(), revenue / 2, 2);

        // The verified staker claims all of it.
        uint256 b0 = bob.balance;
        vm.prank(bob);
        vault.claim();
        assertApproxEqAbs(bob.balance - b0, revenue, 3, "bob receives the whole revenue");
        assertLe(vaultAddr.balance, 3);
        assertEq(vault.totalClaimed() + vault.accountedBalance(), revenue);
    }
}
