// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPortalTypes} from "src/flap/IPortal.sol";
import {Distribution} from "src/flap/Distribution.sol";
import {IStrategy} from "src/flap/IStrategy.sol";
import {ILauncherFactory} from "src/flap/ILauncher.sol";

contract MockLaunchToken is ERC20 {
    constructor(string memory n, string memory s, uint256 supply, address to) ERC20(n, s) {
        _mint(to, supply);
    }
}

/// @notice Minimal stand-in for the Pool Launch Portal, enough to exercise a Launcher end to end:
///         salt lock, newLauncher forwarding, and launchTaxTokenV2 with the EXPLICIT distribution callback.
contract MockPortal {
    uint256 public constant SALT_LOCK_FEE = 0.005 ether;

    mapping(bytes32 => address) public saltLocker;
    mapping(address => address) public launcherFactoryOf;
    mapping(address => bool) public launchedBy;
    mapping(address => bool) public factoryEnabled;

    /// @dev Stand-in for the Portal's liquidity floor (reverts like the live `0xa32ef056(quoteUsd, floorUsd)`).
    uint256 public minPoolQuote;
    error BelowLiquidityFloor(uint256 poolQuote, uint256 minPoolQuote);

    address public lastCommissionReceiver = address(0xdead);
    bytes32 public lastExtensionId;
    bytes public lastExtensionData;

    function setLauncherFactoryMultiplier(address factory, uint16, bool enabled) external {
        factoryEnabled[factory] = enabled;
    }

    function setMinPoolQuote(uint256 q) external {
        minPoolQuote = q;
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

    function launchTaxTokenV2(
        IPortalTypes.CreateTaxTokenParams calldata p,
        Distribution calldata dist,
        IPortalTypes.CreatorBuyParams calldata
    ) external payable returns (address token, address pool) {
        require(launcherFactoryOf[msg.sender] != address(0), "not a recorded launcher");
        require(!launchedBy[msg.sender], "already launched");
        require(saltLocker[p.salt] == msg.sender, "salt locked by another");
        require(msg.value == p.poolQuote + p.creatorBuyQuote, "value");
        if (p.poolQuote < minPoolQuote) revert BelowLiquidityFloor(p.poolQuote, minPoolQuote);
        launchedBy[msg.sender] = true;
        lastCommissionReceiver = p.commissionReceiver;
        lastExtensionId = p.extensionID;
        lastExtensionData = p.extensionData;

        MockLaunchToken t = new MockLaunchToken(p.name, p.symbol, p.totalSupply, address(this));
        token = address(t);
        pool = address(uint160(uint256(keccak256(abi.encode(token, "pool")))));
        t.transfer(pool, p.poolToken);
        t.approve(dist.strategy, dist.amount);
        IStrategy(dist.strategy).initializeDistribution(token, dist.amount, dist.configData, p.salt);
        require(t.allowance(address(this), dist.strategy) == 0, "allowance not consumed");
    }
}
