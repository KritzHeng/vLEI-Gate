// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPortalTypes} from "src/flap/IPortal.sol";
import {Distribution} from "src/flap/Distribution.sol";
import {IStrategy} from "src/flap/IStrategy.sol";
import {ILauncherFactory, LauncherRecord} from "src/flap/ILauncher.sol";
import {IDirectLaunchVaultFactory} from "src/flap/ILaunchVaultSpec.sol";
import {MockLaunchToken} from "./MockPortal.sol";

/// @notice Portal stand-in for the v2 launchers: native OR ERC20 quote (`msg.value == 0`, pulls `poolQuote` from the
///         launcher with `transferFrom`, as the live Portal does after the launcher's approve), optional VAULT slot
///         (`newVault` inside the launch), a liquidity floor, and TaxProcessor-like revenue dispatch.
contract MockPortalV2 {
    uint256 public constant SALT_LOCK_FEE = 0.005 ether;

    mapping(bytes32 => address) public saltLocker;
    mapping(address => address) public launcherFactoryOf;
    mapping(address => bool) public launchedBy;
    mapping(address token => address vault) internal _vaultOf;
    mapping(address token => address factory) internal _vaultFactoryOf;

    uint256 public minPoolQuote;
    error BelowLiquidityFloor(uint256 poolQuote, uint256 minPoolQuote);

    address public lastQuoteToken = address(0xdead);
    uint256 public lastValue = type(uint256).max;
    uint256 public lastQuotePulled;
    address public lastCommissionReceiver = address(0xdead);
    IPortalTypes.FeeConfig[] internal _lastFees;

    function setMinPoolQuote(uint256 q) external {
        minPoolQuote = q;
    }

    function lockSalt(bytes32 salt, uint8) external payable {
        require(msg.value == SALT_LOCK_FEE, "fee");
        require(saltLocker[salt] == address(0), "salt locked");
        saltLocker[salt] = msg.sender;
    }

    function newLauncher(address factory, bytes calldata data) external payable returns (address launcher) {
        launcher = ILauncherFactory(factory).newLauncher{value: msg.value}(msg.sender, data);
        launcherFactoryOf[launcher] = factory;
    }

    function getLauncher(address launcher) external view returns (LauncherRecord memory r) {
        r.launcherFactory = launcherFactoryOf[launcher];
    }

    function getLaunchVault(address token) external view returns (address vault, address vaultFactory) {
        return (_vaultOf[token], _vaultFactoryOf[token]);
    }

    function lastFee(uint256 i) external view returns (IPortalTypes.FeeConfig memory) {
        return _lastFees[i];
    }

    function launchTaxTokenV2(
        IPortalTypes.CreateTaxTokenParams calldata p,
        Distribution calldata dist,
        IPortalTypes.CreatorBuyParams calldata
    ) external payable returns (address token, address pool) {
        require(launcherFactoryOf[msg.sender] != address(0), "not a recorded launcher");
        require(!launchedBy[msg.sender], "already launched");
        require(saltLocker[p.salt] == msg.sender, "salt locked by another");
        if (p.quoteToken == address(0)) {
            require(msg.value == p.poolQuote + p.creatorBuyQuote, "value");
        } else {
            require(msg.value == 0, "IncorrectNativeValue");
        }
        if (p.poolQuote < minPoolQuote) revert BelowLiquidityFloor(p.poolQuote, minPoolQuote);
        launchedBy[msg.sender] = true;
        lastQuoteToken = p.quoteToken;
        lastValue = msg.value;
        lastCommissionReceiver = p.commissionReceiver;
        delete _lastFees;
        for (uint256 i; i < p.feeConfigs.length; ++i) {
            _lastFees.push(p.feeConfigs[i]);
        }

        MockLaunchToken t = new MockLaunchToken(p.name, p.symbol, p.totalSupply, address(this));
        token = address(t);
        pool = address(uint160(uint256(keccak256(abi.encode(token, "pool")))));

        if (p.quoteToken != address(0)) {
            uint256 b = IERC20(p.quoteToken).balanceOf(pool);
            IERC20(p.quoteToken).transferFrom(msg.sender, pool, p.poolQuote + p.creatorBuyQuote);
            lastQuotePulled = IERC20(p.quoteToken).balanceOf(pool) - b;
        }

        for (uint256 i; i < p.feeConfigs.length; ++i) {
            if (p.feeConfigs[i].feeType != IPortalTypes.FeeSlotType.VAULT) continue;
            IPortalTypes.FeeConfigVault memory v = abi.decode(p.feeConfigs[i].configData, (IPortalTypes.FeeConfigVault));
            address vault = IDirectLaunchVaultFactory(v.vaultFactory).newVault(token, msg.sender, 0, abi.encode(p, dist));
            _vaultOf[token] = vault;
            _vaultFactoryOf[token] = v.vaultFactory;
        }

        t.transfer(pool, p.poolToken);
        t.approve(dist.strategy, dist.amount);
        IStrategy(dist.strategy).initializeDistribution(token, dist.amount, dist.configData, p.salt);
        require(t.allowance(address(this), dist.strategy) == 0, "allowance not consumed");
    }

    /// @dev Native revenue: value transfer to the vault.
    function dispatchToVault(address token) external payable {
        (bool ok,) = _vaultOf[token].call{value: msg.value}("");
        require(ok, "vault rejected revenue");
    }

    /// @dev ERC20 revenue the way the TaxProcessor pays a contract recipient: transfer, then a zero-value ping.
    function dispatchToVaultERC20(address token, address quote, uint256 amount, bool ping) external {
        address v = _vaultOf[token];
        IERC20(quote).transferFrom(msg.sender, v, amount);
        if (ping) {
            (bool ok,) = v.call("");
            require(ok, "vault rejected ping");
        }
    }
}
