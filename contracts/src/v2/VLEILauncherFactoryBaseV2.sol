// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LibClone} from "solady/utils/LibClone.sol";
import {UpgradeableBeacon} from "solady/utils/UpgradeableBeacon.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {LauncherFactoryBase} from "src/flap/LauncherFactoryBase.sol";
import {LauncherDataSchema, FieldDescriptor} from "src/flap/IVaultSchemas.sol";

import {VLEIMintConfig} from "../VLEIMintLauncher.sol";
import {VLEILauncherBaseV2} from "./VLEILauncherBaseV2.sol";
import {IVLEIRegistry} from "../interfaces/IVLEIRegistry.sol";
import {IPriceFeed} from "../interfaces/IPriceFeed.sol";

/// @title VLEILauncherFactoryBaseV2
/// @notice Shared v2 launcher factory: vLEI gate (`registry.canLaunch`), minimum target at creation, beacon proxies
///         with an implementation bound to this factory, Guardian-only upgrades, owner limited to `maxPriceAge` /
///         `minTargetUsd`. The quote asset is a FACTORY-level immutable:
///           `quoteToken == address(0)`: native BNB; `priceFeed` (Atlas BNB/USD) is required; USD = amount × feed.
///           otherwise: an 18-decimal ERC20 treated as $1; `priceFeed` must be address(0); USD = amount (1:1).
///         Payload: `abi.encode(VLEIMintConfig)` (same tuple as v1; `targetRaise` is in quote wei).
abstract contract VLEILauncherFactoryBaseV2 is LauncherFactoryBase, Ownable2Step {
    address public immutable hub;
    address public immutable guardian;
    address public immutable beacon;
    IVLEIRegistry public immutable registry;
    /// @notice BNB/USD feed for a native-quote factory; address(0) for an ERC20-quote factory.
    IPriceFeed public immutable priceFeed;
    /// @notice address(0) = native BNB, otherwise the ERC20 quote every launcher of this factory uses.
    address public immutable quoteToken;

    uint256 public constant MAX_PRICE_AGE_LIMIT = 7 days;
    /// @notice Default `minTargetUsd` for a native-quote factory (buffer over the ~$1,500 creation floor for BNB moves).
    uint256 public constant DEFAULT_MIN_TARGET_USD = 1_600e18;
    /// @notice Default `minTargetUsd` for an ERC20 ($1) quote: the Portal's creation floor for a 50% pool at 1x
    ///         multiplier ($750 × 1M / 500k), read on BNB Testnet with `graduationFloorV2`.
    uint256 public constant DEFAULT_MIN_TARGET_ERC20 = 1_500e18;
    uint256 public maxPriceAge;
    /// @notice Minimum `targetRaise` value at creation, USD (18 dp). ERC20 quote: quote units.
    uint256 public minTargetUsd;

    address[] public launchers;
    mapping(address => bool) public isLauncher;

    event FlapLauncherImplementationUpgraded(address implementation);
    event MaxPriceAgeUpdated(uint256 maxPriceAge);
    event MinTargetUsdUpdated(uint256 minTargetUsd);

    error CreatorNotAuthorized(address creator);
    error ZeroAddress();
    error InvalidMaxPriceAge();
    error TargetBelowMinimum(uint256 targetUsd, uint256 minTargetUsd);
    error StalePrice();
    error InvalidPrice();
    /// @notice ERC20 quote factory given a price feed (it must be address(0): no feed on that path).
    error PriceFeedNotUsed(address priceFeed);
    /// @notice The ERC20 quote does not have 18 decimals.
    error UnsupportedQuoteDecimals(uint8 decimals);

    constructor(
        address hub_,
        address guardian_,
        IVLEIRegistry registry_,
        IPriceFeed priceFeed_,
        address quoteToken_,
        uint256 maxPriceAge_,
        address owner_
    ) Ownable(owner_) {
        if (hub_ == address(0) || guardian_ == address(0) || address(registry_) == address(0)) {
            revert ZeroAddress();
        }
        if (maxPriceAge_ == 0 || maxPriceAge_ > MAX_PRICE_AGE_LIMIT) revert InvalidMaxPriceAge();
        if (quoteToken_ == address(0)) {
            if (address(priceFeed_) == address(0)) revert ZeroAddress();
            minTargetUsd = DEFAULT_MIN_TARGET_USD;
        } else {
            if (address(priceFeed_) != address(0)) revert PriceFeedNotUsed(address(priceFeed_));
            uint8 dec = IERC20Metadata(quoteToken_).decimals();
            if (dec != 18) revert UnsupportedQuoteDecimals(dec);
            minTargetUsd = DEFAULT_MIN_TARGET_ERC20;
        }
        hub = hub_;
        guardian = guardian_;
        registry = registry_;
        priceFeed = priceFeed_;
        quoteToken = quoteToken_;
        maxPriceAge = maxPriceAge_;
        beacon = address(new UpgradeableBeacon(address(this), _deployImplementation()));
    }

    // ── variant hooks ───────────────────────────────────────────────────────

    /// @dev Deploy the launcher implementation bound to this factory.
    function _deployImplementation() internal virtual returns (address);

    /// @dev Emit the variant's creation event.
    function _emitCreated(address launcher, address creator, bytes32 lei, VLEIMintConfig memory c) internal virtual;

    /// @dev `launcherDataSchema().description`.
    function _schemaDescription() internal pure virtual returns (string memory);

    // ── LauncherFactoryBase ─────────────────────────────────────────────────

    function _getHub() internal view override returns (address) {
        return hub;
    }

    function _getGuardian() internal view override returns (address) {
        return guardian;
    }

    function _newLauncher(address creator, bytes calldata data) internal override returns (address launcher) {
        if (!registry.canLaunch(creator)) revert CreatorNotAuthorized(creator);
        VLEIMintConfig memory config = abi.decode(data, (VLEIMintConfig));
        uint256 targetUsd = quoteUsd(config.targetRaise);
        if (targetUsd < minTargetUsd) revert TargetBelowMinimum(targetUsd, minTargetUsd);

        launcher = LibClone.deployDeterministicERC1967BeaconProxy(beacon, _proxySalt(creator, config.salt));
        VLEILauncherBaseV2(payable(launcher)).initialize{value: msg.value}(hub, creator, config);

        launchers.push(launcher);
        isLauncher[launcher] = true;
        _emitCreated(launcher, creator, registry.leiHashOf(creator), config);
    }

    function upgradeVaultImplementation(address newImplementation) external override onlyGuardian {
        UpgradeableBeacon(beacon).upgradeTo(newImplementation);
        emit FlapLauncherImplementationUpgraded(newImplementation);
    }

    function setMaxPriceAge(uint256 maxPriceAge_) external onlyOwner {
        if (maxPriceAge_ == 0 || maxPriceAge_ > MAX_PRICE_AGE_LIMIT) revert InvalidMaxPriceAge();
        maxPriceAge = maxPriceAge_;
        emit MaxPriceAgeUpdated(maxPriceAge_);
    }

    /// @notice Set the minimum value of `targetRaise` (USD 18 dp; ERC20 quote: quote units). 0 disables it.
    function setMinTargetUsd(uint256 minTargetUsd_) external onlyOwner {
        minTargetUsd = minTargetUsd_;
        emit MinTargetUsdUpdated(minTargetUsd_);
    }

    // ── Views ───────────────────────────────────────────────────────────────

    /// @notice USD value (18 dp) of `amount` of the quote. ERC20: `amount` (1:1). Native: feed, reverts
    ///         InvalidPrice / StalePrice.
    function quoteUsd(uint256 amount) public view returns (uint256) {
        if (quoteToken != address(0)) return amount;
        (, int256 answer,, uint256 updatedAt,) = priceFeed.latestRoundData();
        if (answer <= 0) revert InvalidPrice();
        if (updatedAt > block.timestamp || block.timestamp - updatedAt > maxPriceAge) revert StalePrice();
        // forge-lint: disable-next-line(unsafe-typecast)
        return (amount * uint256(answer)) / (10 ** priceFeed.decimals());
    }

    function beaconImplementation() external view returns (address) {
        return UpgradeableBeacon(beacon).implementation();
    }

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

    function launcherDataSchema() external pure override returns (LauncherDataSchema memory schema) {
        schema.description = _schemaDescription();
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
            description: "Target in the factory's quote asset (BNB or USDT, 18 decimals) that must be reached before the launch (also the pool quote); must be worth at least minTargetUsd at creation",
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
            description: "Max USD one verified legal entity (LEI) may contribute, across all its wallets (USDT quote: 1 USDT = $1)",
            decimals: 18
        });
        schema.fields = fields;
    }
}
