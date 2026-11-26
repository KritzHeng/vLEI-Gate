// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPortalTypes} from "src/flap/IPortal.sol";
import {Distribution} from "src/flap/Distribution.sol";
import {IStrategy} from "src/flap/IStrategy.sol";
import {ILauncherFactory, LauncherRecord} from "src/flap/ILauncher.sol";
import {IDirectLaunchVaultFactory} from "src/flap/ILaunchVaultSpec.sol";
import {MockLaunchToken} from "./MockPortal.sol";

/// @notice Portal stand-in that also resolves a VAULT fee slot the way the live Portal does: it calls
///         `vaultFactory.newVault(token, launchCaller, 0, abi.encode(p, distribution))` inside `launchTaxTokenV2`
///         and records `getLaunchVault(token)`. It also exposes `getLauncher(launcher).launcherFactory`.
/// @dev Simplification: the token is deployed before `newVault` (the real Portal passes a CREATE2 prediction). The
///      vault never calls the token during `newVault`, so the order does not matter for these tests.
contract MockVaultPortal {
    uint256 public constant SALT_LOCK_FEE = 0.005 ether;

    mapping(bytes32 => address) public saltLocker;
    mapping(address => address) public launcherFactoryOf;
    mapping(address => bool) public launchedBy;
    mapping(address => bool) public factoryEnabled;
    mapping(address token => address vault) internal _vaultOf;
    mapping(address token => address factory) internal _vaultFactoryOf;

    address public lastCommissionReceiver = address(0xdead);
    IPortalTypes.FeeConfig[] internal _lastFees;

    function setLauncherFactoryMultiplier(address factory, uint16, bool enabled) external {
        factoryEnabled[factory] = enabled;
    }

    function lockSalt(bytes32 salt, uint8) external payable {
        require(msg.value == SALT_LOCK_FEE, "fee");
        require(saltLocker[salt] == address(0), "salt locked");
        saltLocker[salt] = msg.sender;
    }

    function newLauncher(address factory, bytes calldata data) external payable returns (address launcher) {
        require(factoryEnabled[factory], "factory not enabled");
        launcher = ILauncherFactory(factory).newLauncher{value: msg.value}(msg.sender, data);
        launcherFactoryOf[launcher] = factory;
    }

    function getLauncher(address launcher) external view returns (LauncherRecord memory r) {
        r.launcherFactory = launcherFactoryOf[launcher];
    }

    function getLaunchVault(address token) external view returns (address vault, address vaultFactory) {
        return (_vaultOf[token], _vaultFactoryOf[token]);
    }

    function lastFeeCount() external view returns (uint256) {
        return _lastFees.length;
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
        require(msg.value == p.poolQuote + p.creatorBuyQuote, "value");
        launchedBy[msg.sender] = true;
        lastCommissionReceiver = p.commissionReceiver;
        delete _lastFees;
        uint256 sum;
        for (uint256 i; i < p.feeConfigs.length; ++i) {
            _lastFees.push(p.feeConfigs[i]);
            sum += p.feeConfigs[i].bps;
        }
        require(sum == 10_000, "fee bps");

        MockLaunchToken t = new MockLaunchToken(p.name, p.symbol, p.totalSupply, address(this));
        token = address(t);

        for (uint256 i; i < p.feeConfigs.length; ++i) {
            if (p.feeConfigs[i].feeType != IPortalTypes.FeeSlotType.VAULT) continue;
            IPortalTypes.FeeConfigVault memory v = abi.decode(p.feeConfigs[i].configData, (IPortalTypes.FeeConfigVault));
            address vault = IDirectLaunchVaultFactory(v.vaultFactory).newVault(token, msg.sender, 0, abi.encode(p, dist));
            require(vault.code.length > 0, "vault has no code");
            _vaultOf[token] = vault;
            _vaultFactoryOf[token] = v.vaultFactory;
        }

        pool = address(uint160(uint256(keccak256(abi.encode(token, "pool")))));
        t.transfer(pool, p.poolToken);
        t.approve(dist.strategy, dist.amount);
        IStrategy(dist.strategy).initializeDistribution(token, dist.amount, dist.configData, p.salt);
        require(t.allowance(address(this), dist.strategy) == 0, "allowance not consumed");
    }

    /// @dev Stand-in for the TaxProcessor paying the VAULT slot: native value with the dispatcher's gas.
    function dispatchToVault(address token) external payable {
        (bool ok,) = _vaultOf[token].call{value: msg.value}("");
        require(ok, "vault rejected revenue");
    }
}
