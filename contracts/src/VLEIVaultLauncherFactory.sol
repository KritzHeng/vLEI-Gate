// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LibClone} from "solady/utils/LibClone.sol";
import {UpgradeableBeacon} from "solady/utils/UpgradeableBeacon.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {LauncherFactoryBase} from "src/flap/LauncherFactoryBase.sol";
import {LauncherDataSchema, FieldDescriptor} from "src/flap/IVaultSchemas.sol";

import {VLEIMintConfig} from "./VLEIMintLauncher.sol";
import {VLEIMintVaultLauncher} from "./VLEIMintVaultLauncher.sol";
import {IVLEIRegistry} from "./interfaces/IVLEIRegistry.sol";
import {IPriceFeed} from "./interfaces/IPriceFeed.sol";

/// @notice The one getter this factory reads from its paired vault factory.
interface IPairedVaultFactory {
    function launcherFactory() external view returns (address);
}

/// @title VLEIVaultLauncherFactory
/// @notice `VLEILauncherFactory` for the gated-yield variant: same vLEI gate and config (`VLEIMintConfig`), but it
///         deploys `VLEIMintVaultLauncher`s, whose tax VAULT slot names `vaultFactory` (a `VLEIDividendVaultFactory`
///         that in turn only serves this factory's launchers). The pairing is checked both ways at construction.
///
///         Call path (same as Flap's MintLauncherFactory):
///           Portal.newLauncher{value: SALT_LOCK_FEE}(factory, abi.encode(VLEIMintConfig))
///             -> factory.newLauncher(creator, data)                      (onlyHub, LauncherFactoryBase)
///             -> require registry.canLaunch(creator)                     (CreatorNotAuthorized)
///             -> LibClone.deployDeterministicERC1967BeaconProxy(beacon, keccak256(creator, salt))
///             -> VLEIMintVaultLauncher.initialize{value: fee}(hub, creator, config)   (locks the salt)
///
///         Launchers are beacon proxies; only the Flap Guardian can retarget the beacon. The owner can only tune
///         `maxPriceAge` (the staleness bound every launcher reads live).
contract VLEIVaultLauncherFactory is LauncherFactoryBase, Ownable2Step {
    address public immutable hub;
    address public immutable guardian;
    address public immutable beacon;
    IVLEIRegistry public immutable registry;
    IPriceFeed public immutable priceFeed;
    /// @notice The paired `VLEIDividendVaultFactory` every launcher of this factory names in its VAULT fee slot.
    address public immutable vaultFactory;

    uint256 public constant MAX_PRICE_AGE_LIMIT = 7 days;
    /// @notice Default minimum value of `targetRaise` in USD (18 dp). The live Portal rejects launches below its
    ///         liquidity floor (about $1,500 on BNB Testnet); a sale below it could never launch.
    uint256 public constant DEFAULT_MIN_TARGET_USD = 1_600e18;
    uint256 public maxPriceAge;
    /// @notice Minimum `targetRaise` value in USD (18 dp), checked with the BNB/USD feed at creation.
    uint256 public minTargetUsd = DEFAULT_MIN_TARGET_USD;

    address[] public launchers;
    mapping(address => bool) public isLauncher;

    event VLEIVaultLauncherCreated(
        address indexed launcher,
        address indexed creator,
        bytes32 indexed creatorLeiHash,
        bytes32 launchSalt,
        uint256 targetRaise,
        uint256 capUsdPerEntity
    );
    event FlapLauncherImplementationUpgraded(address implementation);
    event MaxPriceAgeUpdated(uint256 maxPriceAge);
    event MinTargetUsdUpdated(uint256 minTargetUsd);

    error CreatorNotAuthorized(address creator);
    error ZeroAddress();
    error InvalidMaxPriceAge();
    error TargetBelowMinimum(uint256 targetUsd, uint256 minTargetUsd);
    error StalePrice();
    error InvalidPrice();
    error VaultFactoryNotPaired(address vaultFactory);

    /// @dev Deploys the Launcher implementation itself, bound to this factory (`VLEIMintVaultLauncher.factory`), so a
    ///      proxy of it can only be initialized from here.
    constructor(
        address hub_,
        address guardian_,
        IVLEIRegistry registry_,
        IPriceFeed priceFeed_,
        uint256 maxPriceAge_,
        address owner_,
        address vaultFactory_
    ) Ownable(owner_) {
        if (
            hub_ == address(0) || guardian_ == address(0) || address(registry_) == address(0) || address(priceFeed_) == address(0)
        ) revert ZeroAddress();
        if (maxPriceAge_ == 0 || maxPriceAge_ > MAX_PRICE_AGE_LIMIT) revert InvalidMaxPriceAge();
        if (vaultFactory_ == address(0)) revert ZeroAddress();
        if (IPairedVaultFactory(vaultFactory_).launcherFactory() != address(this)) {
            revert VaultFactoryNotPaired(vaultFactory_);
        }
        vaultFactory = vaultFactory_;
        hub = hub_;
        guardian = guardian_;
        registry = registry_;
        priceFeed = priceFeed_;
        maxPriceAge = maxPriceAge_;
        VLEIMintVaultLauncher impl = new VLEIMintVaultLauncher(address(this));
        beacon = address(new UpgradeableBeacon(address(this), address(impl)));
    }

    function _getHub() internal view override returns (address) {
        return hub;
    }

    function _getGuardian() internal view override returns (address) {
        return guardian;
    }

    /// @inheritdoc LauncherFactoryBase
    function _newLauncher(address creator, bytes calldata data) internal override returns (address launcher) {
        if (!registry.canLaunch(creator)) revert CreatorNotAuthorized(creator);
        VLEIMintConfig memory config = abi.decode(data, (VLEIMintConfig));
        uint256 targetUsd = quoteUsd(config.targetRaise);
        if (targetUsd < minTargetUsd) revert TargetBelowMinimum(targetUsd, minTargetUsd);

        launcher = LibClone.deployDeterministicERC1967BeaconProxy(beacon, _proxySalt(creator, config.salt));
        VLEIMintVaultLauncher(payable(launcher)).initialize{value: msg.value}(hub, creator, config);

        launchers.push(launcher);
        isLauncher[launcher] = true;
        emit VLEIVaultLauncherCreated(
            launcher, creator, registry.leiHashOf(creator), config.salt, config.targetRaise, config.capUsdPerEntity
        );
    }

    /// @inheritdoc LauncherFactoryBase
    function upgradeVaultImplementation(address newImplementation) external override onlyGuardian {
        UpgradeableBeacon(beacon).upgradeTo(newImplementation);
        emit FlapLauncherImplementationUpgraded(newImplementation);
    }

    function setMaxPriceAge(uint256 maxPriceAge_) external onlyOwner {
        if (maxPriceAge_ == 0 || maxPriceAge_ > MAX_PRICE_AGE_LIMIT) revert InvalidMaxPriceAge();
        maxPriceAge = maxPriceAge_;
        emit MaxPriceAgeUpdated(maxPriceAge_);
    }

    /// @notice Set the minimum USD value of `targetRaise` (0 disables the check).
    function setMinTargetUsd(uint256 minTargetUsd_) external onlyOwner {
        minTargetUsd = minTargetUsd_;
        emit MinTargetUsdUpdated(minTargetUsd_);
    }

    // ── Views ───────────────────────────────────────────────────────────────

    /// @notice USD value (18 dp) of `bnbAmount` from the feed. Reverts InvalidPrice / StalePrice.
    function quoteUsd(uint256 bnbAmount) public view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = priceFeed.latestRoundData();
        if (answer <= 0) revert InvalidPrice();
        if (updatedAt > block.timestamp || block.timestamp - updatedAt > maxPriceAge) revert StalePrice();
        // forge-lint: disable-next-line(unsafe-typecast)
        return (bnbAmount * uint256(answer)) / (10 ** priceFeed.decimals());
    }

    function beaconImplementation() external view returns (address) {
        return UpgradeableBeacon(beacon).implementation();
    }

    /// @notice Address the Launcher for (`creator`, `salt`) will have.
    function predictLauncher(address creator, bytes32 salt) external view returns (address) {
        return LibClone.predictDeterministicAddressERC1967BeaconProxy(beacon, _proxySalt(creator, salt), address(this));
    }

    function launcherCount() external view returns (uint256) {
        return launchers.length;
    }

    function getLaunchers() external view returns (address[] memory) {
        return launchers;
    }

    function _proxySalt(address creator, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encode(creator, salt));
    }

    /// @inheritdoc LauncherFactoryBase
    function launcherDataSchema() external pure override returns (LauncherDataSchema memory schema) {
        schema.description =
            "vLEI-gated contribution round with gated yield. Only a vLEI-verified OOR officer can create it; only verified legal entities can contribute, each capped in USD (Atlas BNB/USD). The raise and 50% of the supply seed the pool, the other 50% is claimed by verified contributors pro rata. 75% of the token's tax goes to a paired vault that pays only stakers who are vLEI-verified (no fee). Refunds if the target is missed or the creator's vLEI is revoked.";
        schema.isArray = false;

        FieldDescriptor[] memory fields = new FieldDescriptor[](7);
        fields[0] = FieldDescriptor({name: "name", fieldType: "string", description: "Token name", decimals: 0});
        fields[1] = FieldDescriptor({name: "symbol", fieldType: "string", description: "Token symbol", decimals: 0});
        fields[2] = FieldDescriptor({name: "meta", fieldType: "string", description: "Metadata URI", decimals: 0});
        fields[3] = FieldDescriptor({
            name: "salt",
            fieldType: "bytes32",
            description: "CREATE2 salt; vanity-mined so the token address ends in 0x7777",
            decimals: 0
        });
        fields[4] = FieldDescriptor({
            name: "targetRaise",
            fieldType: "uint256",
            description: "BNB target that must be reached before the launch (also the pool quote); must be worth at least minTargetUsd (default $1,600) at creation",
            decimals: 18
        });
        fields[5] = FieldDescriptor({
            name: "saleDuration",
            fieldType: "uint256",
            description: "Contribution window in seconds (max 30 days)",
            decimals: 0
        });
        fields[6] = FieldDescriptor({
            name: "capUsdPerEntity",
            fieldType: "uint256",
            description: "Max USD one verified legal entity (LEI) may contribute, across all its wallets",
            decimals: 18
        });
        schema.fields = fields;
    }
}
