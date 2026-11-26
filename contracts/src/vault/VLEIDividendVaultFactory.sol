// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPortal, IPortalTypes} from "src/flap/IPortal.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {UpgradeableBeacon} from "solady/utils/UpgradeableBeacon.sol";
import {DirectLaunchVaultFactoryBase} from "src/flap/DirectLaunchVaultFactoryBase.sol";
import {Distribution} from "src/flap/Distribution.sol";
import {VaultDataSchema, FieldDescriptor, FactoryPolicy} from "src/flap/IVaultSchemas.sol";

import {VLEIDividendVault} from "./VLEIDividendVault.sol";

/// @notice What the factory asks a launcher to prove about itself.
interface IVLEIVaultLauncherCheck {
    function launching() external view returns (bool);
    function raised() external view returns (uint256);
    function targetRaise() external view returns (uint256);
}

/// @title VLEIDividendVaultFactory
/// @notice Pool Launch vault factory paired with `VLEIVaultLauncherFactory` (the Crowd pattern): it deploys one
///         `VLEIDividendVault` per launch, and only for launches made by a `VLEIMintVaultLauncher` of that factory.
///
///         `newVault` checks, before deploying anything (all rejected, none defaulted):
///           1. caller is the Portal (`onlyHub`); `_validateLaunch` passes (one VAULT slot naming this factory,
///              non-zero bps, supported quote, DIRECT_V2_POOL_TAX kind); no reserve is routed to the vault;
///           2. `creator` (the launch caller) is a Launcher the Portal recorded for `launcherFactory`;
///           3. `vaultData` is exactly `abi.encode(address launcher)` and names that same Launcher;
///           4. native BNB quote, VAULT slot exactly `VAULT_SLOT_BPS` (75%), no commission receiver;
///           5. the Launcher is mid-launch with the full raise in.
///
///         Upgrades: Guardian only, through the beacon. No owner, no other privileged function.
contract VLEIDividendVaultFactory is DirectLaunchVaultFactoryBase {
    address public immutable hub;
    address public immutable guardian;
    address public immutable beacon;
    /// @notice The only Launcher factory whose Launchers this vault factory serves. Fixed at construction.
    address public immutable launcherFactory;

    uint16 public constant VAULT_SLOT_BPS = 7500;

    mapping(address token => address vault) public vaultOf;

    error NotFromLauncherFactory(address launcher);
    error VaultDataLauncherMismatch(address expected, address got);
    error VaultSlotBpsMismatch(uint16 got, uint16 expected);
    error NativeQuoteOnly(address quoteToken);
    error CommissionNotAllowed(address receiver);
    error LauncherNotLaunching(address launcher);
    error LauncherNotFunded(uint256 raised, uint256 target);

    event FlapVaultImplementationUpgraded(address implementation);
    event VLEIDividendVaultCreated(address indexed vault, address indexed token, address indexed launcher);

    constructor(address hub_, address guardian_, address launcherFactory_) {
        if (hub_ == address(0) || guardian_ == address(0) || launcherFactory_ == address(0)) revert ZeroAddress();
        hub = hub_;
        guardian = guardian_;
        launcherFactory = launcherFactory_;
        beacon = address(new UpgradeableBeacon(address(this), address(new VLEIDividendVault(address(this)))));
    }

    function _getHub() internal view override returns (address) {
        return hub;
    }

    function _getGuardian() internal view override returns (address) {
        return guardian;
    }

    /// @inheritdoc DirectLaunchVaultFactoryBase
    function newVault(address token, address creator, uint8 launchKind, bytes calldata launchParams)
        external
        override
        onlyHub
        returns (address vault)
    {
        (IPortalTypes.CreateTaxTokenParams memory p, Distribution memory d, bytes memory vaultData) =
            _validateLaunch(token, creator, launchKind, launchParams);
        _requireNoReserveDistribution(d);

        if (IPortal(hub).getLauncher(creator).launcherFactory != launcherFactory) {
            revert NotFromLauncherFactory(creator);
        }
        if (vaultData.length != 32) revert InvalidVaultData();
        address named = abi.decode(vaultData, (address));
        if (named != creator) revert VaultDataLauncherMismatch(creator, named);

        if (p.quoteToken != address(0)) revert NativeQuoteOnly(p.quoteToken);
        if (p.commissionReceiver != address(0)) revert CommissionNotAllowed(p.commissionReceiver);
        uint16 slotBps = _vaultSlotBps(p.feeConfigs);
        if (slotBps != VAULT_SLOT_BPS) revert VaultSlotBpsMismatch(slotBps, VAULT_SLOT_BPS);

        IVLEIVaultLauncherCheck l = IVLEIVaultLauncherCheck(creator);
        if (!l.launching()) revert LauncherNotLaunching(creator);
        if (l.raised() != l.targetRaise()) revert LauncherNotFunded(l.raised(), l.targetRaise());

        vault = LibClone.deployDeterministicERC1967BeaconProxy(beacon, bytes32(uint256(uint160(token))));
        VLEIDividendVault(payable(vault)).initialize(token, creator);
        vaultOf[token] = vault;
        emit VLEIDividendVaultCreated(vault, token, creator);
    }

    /// @dev `_validateLaunch` already guarantees exactly one VAULT slot naming this factory.
    function _vaultSlotBps(IPortalTypes.FeeConfig[] memory fees) internal view returns (uint16) {
        for (uint256 i; i < fees.length; ++i) {
            if (fees[i].feeType != IPortalTypes.FeeSlotType.VAULT) continue;
            IPortalTypes.FeeConfigVault memory v = abi.decode(fees[i].configData, (IPortalTypes.FeeConfigVault));
            if (v.vaultFactory == address(this)) return fees[i].bps;
        }
        return 0;
    }

    /// @notice The vault address `newVault` will deploy for `token`.
    function predictVault(address token) external view returns (address) {
        return LibClone.predictDeterministicAddressERC1967BeaconProxy(
            beacon, bytes32(uint256(uint160(token))), address(this)
        );
    }

    /// @inheritdoc DirectLaunchVaultFactoryBase
    function vaultDataSchema() public pure override returns (VaultDataSchema memory schema) {
        schema.description = "vLEI gated-yield vault: the token's BNB tax revenue goes only to stakers verified as "
            "legal entities in VLEIRegistry. No fee. Set by the VLEIMintVaultLauncher, not by hand.";
        schema.fields = new FieldDescriptor[](1);
        schema.fields[0] = FieldDescriptor("launcher", "address", "The VLEIMintVaultLauncher that is launching", 0);
    }

    /// @inheritdoc DirectLaunchVaultFactoryBase
    function isQuoteTokenSupported(address quoteToken) public pure override returns (bool) {
        return quoteToken == address(0);
    }

    /// @inheritdoc DirectLaunchVaultFactoryBase
    function factorySpecVersion() public pure override returns (string memory) {
        return "pl-v1";
    }

    /// @inheritdoc DirectLaunchVaultFactoryBase
    function tokenCreationPolicies() public pure override returns (FactoryPolicy[] memory policies) {
        policies = new FactoryPolicy[](3);
        policies[0] = FactoryPolicy({
            target: "quoteToken", operator: "eq", value: abi.encode(address(0)), description: "Native BNB quote only."
        });
        policies[1] = FactoryPolicy({
            target: "vaultSlotBps",
            operator: "eq",
            value: abi.encode(uint256(VAULT_SLOT_BPS)),
            description: "The VAULT slot must take exactly 75% of the tax."
        });
        policies[2] = FactoryPolicy({
            target: "commissionReceiver",
            operator: "eq",
            value: abi.encode(address(0)),
            description: "No developer commission."
        });
    }

    /// @inheritdoc DirectLaunchVaultFactoryBase
    function upgradeVaultImplementation(address newImplementation) external override onlyGuardian {
        UpgradeableBeacon(beacon).upgradeTo(newImplementation);
        emit FlapVaultImplementationUpgraded(newImplementation);
    }

    function beaconImplementation() external view returns (address) {
        return UpgradeableBeacon(beacon).implementation();
    }
}
