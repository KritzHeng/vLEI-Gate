// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPortalTypes, IPortal} from "src/flap/IPortal.sol";
import {LauncherBase} from "src/flap/LauncherBase.sol";
import {Distribution, DistributionTarget} from "src/flap/Distribution.sol";
import {IStrategy} from "src/flap/IStrategy.sol";
import {LaunchExtensionHelper} from "src/flap/LaunchExtensionHelper.sol";
import {LauncherDescription} from "src/flap/LauncherHelper.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IVLEIRegistry} from "./interfaces/IVLEIRegistry.sol";
import {IPriceFeed} from "./interfaces/IPriceFeed.sol";

string constant VLEI_TITLE_ZH = unicode"vLEI 认证募资发射";
string constant VLEI_TITLE_EN = "vLEI-gated contribution round";
string constant VLEI_SUMMARY_ZH =
    unicode"仅限通过 vLEI 认证的法人参与。持续募集 BNB 直至达到目标，募集的 BNB 与 50% 的代币供应注入流动性池，另外 50% 由已认证的贡献者按出资比例领取。每个法人的出资以 USD 计有上限。";
string constant VLEI_SUMMARY_EN =
    "Only vLEI-verified legal entities may contribute. BNB is collected until the target is met; the raise and 50% of the supply then seed the pool and the other 50% is claimed by verified contributors pro rata. Each entity has a USD cap.";

/// @notice Payload the creator passes to `Portal.newLauncher(factory, abi.encode(VLEIMintConfig))`.
/// @param name            Token name.
/// @param symbol          Token symbol.
/// @param meta            Metadata URI, passed to the token unchanged.
/// @param salt            CREATE2 launch salt; the predicted token address must end in `0x7777`.
/// @param targetRaise     BNB (wei) that must be raised before the launch; becomes `poolQuote`.
/// @param saleDuration    Contribution window in seconds, counted from creation.
/// @param capUsdPerEntity Max USD (18 decimals) one legal entity (leiHash) may contribute, across all its wallets.
struct VLEIMintConfig {
    string name;
    string symbol;
    string meta;
    bytes32 salt;
    uint256 targetRaise;
    uint256 saleDuration;
    uint256 capUsdPerEntity;
}

/// @dev What the launcher reads from its factory.
interface IVLEILauncherFactoryConfig {
    function registry() external view returns (IVLEIRegistry);
    function priceFeed() external view returns (IPriceFeed);
    function maxPriceAge() external view returns (uint256);
    function minTargetUsd() external view returns (uint256);
}

/// @dev Extra read surface of `VLEIRegistry` (public getters) used only for UI views.
interface IVLEIRegistryDetails {
    struct Registration {
        bytes32 leiHash;
        uint8 role;
        uint64 expiresAt;
        uint64 registeredAt;
        address verifier;
    }

    function getRegistration(address wallet) external view returns (Registration memory);
    function walletRevoked(address wallet) external view returns (bool);
    function entityRevoked(bytes32 leiHash) external view returns (bool);
}

/// @title VLEIMintLauncher
/// @notice Fork of Flap's reference `MintLauncher` with a vLEI compliance gate:
///         - only wallets active in `VLEIRegistry` may contribute or claim;
///         - the sale stops when the creator (an OOR officer) is no longer active, and anyone can then cancel it so
///           every contributor is refunded immediately;
///         - each legal entity (leiHash) may contribute at most `capUsdPerEntity` USD, valued with the Atlas BNB/USD
///           feed (aggregator interface, staleness-checked);
///         - a contributor whose registration is revoked before the launch may withdraw their BNB.
///         Launch economics are unchanged from MintLauncher: the contribution that reaches `targetRaise` calls
///         `Portal.launchTaxTokenV2` in the same transaction, half the supply seeds the pool, half is claimed pro
///         rata, and there is no developer commission (`commissionReceiver = address(0)`).
/// @dev Deployed by `VLEILauncherFactory` as an ERC1967 beacon proxy; the Flap Guardian is the only upgrade path.
contract VLEIMintLauncher is LauncherBase, Initializable, ReentrancyGuard, IStrategy {
    using SafeTransferLib for address;

    uint256 public constant TOTAL_SUPPLY = 1_000_000 ether;
    uint256 public constant POOL_TOKEN = TOTAL_SUPPLY / 2;
    uint256 internal constant DISTRIBUTED_TOKEN = TOTAL_SUPPLY - POOL_TOKEN;

    /// @notice Longest allowed contribution window.
    uint256 public constant MAX_SALE_DURATION = 30 days;
    /// @notice How long after the creator's registration EXPIRES (without a revocation) anyone may cancel.
    uint256 public constant CREATOR_EXPIRY_GRACE = 7 days;
    /// @notice Gas that must be left when the Portal launch is attempted. Prevents a caller from forcing the launch
    ///         to fail by out-of-gas (63/64 rule) and so marking a healthy sale as failed. A launch uses about 4.2M.
    uint256 public constant MIN_LAUNCH_GAS = 7_000_000;
    uint8 internal constant ROLE_OOR_OFFICER = 3;

    /// @notice The only factory allowed to initialize proxies of this implementation.
    address public immutable factory;

    /// @notice `status()` values. A launch the Portal rejected (e.g. below its liquidity floor) reports FAILED too;
    ///         `launchFailed()` tells the two apart.
    uint8 public constant STATUS_RAISING = 0;
    uint8 public constant STATUS_LAUNCHED = 1;
    uint8 public constant STATUS_FAILED = 2;
    uint8 public constant STATUS_CANCELLED = 3;

    /// @notice `vleiStatusOf()` values.
    uint8 public constant VLEI_NONE = 0;
    uint8 public constant VLEI_ACTIVE = 1;
    uint8 public constant VLEI_EXPIRED = 2;
    uint8 public constant VLEI_WALLET_REVOKED = 3;
    uint8 public constant VLEI_ENTITY_REVOKED = 4;

    // ── Flap MintLauncher state ─────────────────────────────────────────────
    address public hub;
    address public creator;
    bytes32 public launchSalt;
    uint256 public targetRaise;
    uint256 public saleDeadline;
    string public name;
    string public symbol;
    string public meta;
    uint256 public raised;
    mapping(address account => uint256 amount) public contributions;
    bool public launched;
    bool internal launching;
    bool internal distributionInitialized;
    address public token;
    address public pool;
    mapping(address account => uint256 amount) public claimed;

    // ── vLEI state ──────────────────────────────────────────────────────────
    IVLEIRegistry public registry;
    IPriceFeed public priceFeed;
    uint256 public capUsdPerEntity;
    bool public cancelled;
    /// @notice Set when the Portal rejected the launch; everyone can then refund.
    bool public launchFailed;
    /// @notice The creator's leiHash at creation. The sale is bound to this entity.
    bytes32 public creatorLei;
    /// @notice USD (18 dp) contributed per legal entity, across all its wallets.
    mapping(bytes32 leiHash => uint256 usd) public investedUsd;
    /// @notice USD (18 dp) booked for each wallet at contribution time; unwound on withdraw / refund.
    mapping(address account => uint256 usd) public contributedUsdOf;
    /// @notice The entity a wallet contributed for.
    mapping(address account => bytes32 leiHash) public contributorLei;

    event Contributed(
        address indexed account, bytes32 indexed leiHash, uint256 amount, uint256 usdValue, uint256 bnbUsd
    );
    event ContributionWithdrawn(address indexed account, bytes32 indexed leiHash, uint256 amount, uint256 usdValue);
    event SaleCancelled(address indexed caller, address indexed creator);
    event LaunchFailed(bytes reason);
    event ExcessRefunded(address indexed account, uint256 amount);
    event Launched(address indexed token, address indexed pool, uint256 poolQuote, uint256 poolToken);
    event Claimed(address indexed account, uint256 amount);
    event Refunded(address indexed account, uint256 amount);

    error InvalidConfig();
    error SaleClosed();
    error SaleIsCancelled();
    error AlreadyCancelled();
    error AlreadyLaunched();
    error ZeroContribution();
    error LaunchInProgress();
    error UnauthorizedDistribution();
    error DistributionNotInitialized();
    error NothingToClaim();
    error RefundUnavailable();
    error NothingToRefund();
    error NothingToWithdraw();
    error EthTransferFailed();
    error NotVerified();
    error IssuerNotActive();
    error IssuerStillActive();
    error StillVerified();
    error EntityMismatch();
    error CapExceeded(uint256 invested, uint256 attempted, uint256 cap);
    error StalePrice();
    error InvalidPrice();
    error NotFactory(address caller);
    error InsufficientLaunchGas(uint256 gasLeft, uint256 required);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address factory_) {
        if (factory_ == address(0)) revert InvalidConfig();
        factory = factory_;
        _disableInitializers();
    }

    /// @notice Called once by the factory in the transaction that deploys the proxy. `msg.value` is the salt-lock
    ///         fee; the Launcher pays it so the Portal records this proxy as the salt's locker.
    function initialize(address hub_, address creator_, VLEIMintConfig calldata c) external payable initializer {
        if (msg.sender != factory) revert NotFactory(msg.sender);
        if (hub_ == address(0) || creator_ == address(0)) revert InvalidConfig();
        if (c.salt == bytes32(0) || c.targetRaise == 0 || c.capUsdPerEntity == 0) revert InvalidConfig();
        if (c.saleDuration == 0 || c.saleDuration > MAX_SALE_DURATION) revert InvalidConfig();

        hub = hub_;
        creator = creator_;
        launchSalt = c.salt;
        targetRaise = c.targetRaise;
        saleDeadline = block.timestamp + c.saleDuration;
        name = c.name;
        symbol = c.symbol;
        meta = c.meta;
        capUsdPerEntity = c.capUsdPerEntity;

        registry = IVLEILauncherFactoryConfig(msg.sender).registry();
        priceFeed = IVLEILauncherFactoryConfig(msg.sender).priceFeed();
        if (address(registry) == address(0) || address(priceFeed) == address(0)) revert InvalidConfig();
        creatorLei = registry.leiHashOf(creator_);

        uint256 fee = IPortal(hub_).SALT_LOCK_FEE();
        if (msg.value != fee) revert InvalidConfig();
        IPortal(hub_).lockSalt{value: fee}(c.salt, uint8(IPortalTypes.LaunchKind.DIRECT_V2_POOL_TAX));
    }

    function _getHub() internal view override returns (address) {
        return hub;
    }

    function _description() internal view override returns (LauncherDescription memory d) {
        d.name = name;
        d.symbol = symbol;
        d.quoteToken = address(0);
        d.targetRaise = targetRaise;
        d.poolTokenRatio = (POOL_TOKEN * 1e18) / TOTAL_SUPPLY;
        d.titleZh = VLEI_TITLE_ZH;
        d.titleEn = VLEI_TITLE_EN;
        d.summaryZh = VLEI_SUMMARY_ZH;
        d.summaryEn = VLEI_SUMMARY_EN;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Contribution round
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Add BNB to the raise. Sender must be vLEI-active, the creator must still be an active OOR officer of
    ///         the same entity, and the sender's entity must stay within `capUsdPerEntity`. Only what is still needed
    ///         to reach `targetRaise` is accepted; any excess is sent back at the end of the call. The call that
    ///         reaches `targetRaise` also launches.
    function contribute() external payable nonReentrant {
        if (launching) revert LaunchInProgress();
        if (cancelled) revert SaleIsCancelled();
        if (launched) revert AlreadyLaunched();
        if (launchFailed || block.timestamp >= saleDeadline) revert SaleClosed();
        if (msg.value == 0) revert ZeroContribution();
        if (!registry.isActive(msg.sender)) revert NotVerified();
        if (!_creatorActive()) revert IssuerNotActive();

        uint256 accepted = targetRaise - raised;
        if (msg.value < accepted) accepted = msg.value;
        uint256 excess = msg.value - accepted;

        bytes32 lei = registry.leiHashOf(msg.sender);
        bytes32 prior = contributorLei[msg.sender];
        if (prior != bytes32(0) && prior != lei) revert EntityMismatch();

        uint256 price = _priceStrict();
        uint256 usd = (accepted * price) / 1e18;
        uint256 invested = investedUsd[lei];
        if (invested + usd > capUsdPerEntity) revert CapExceeded(invested, usd, capUsdPerEntity);

        contributorLei[msg.sender] = lei;
        investedUsd[lei] = invested + usd;
        contributedUsdOf[msg.sender] += usd;
        raised += accepted;
        contributions[msg.sender] += accepted;
        emit Contributed(msg.sender, lei, accepted, usd, price);

        if (raised == targetRaise) _launch();

        if (excess > 0) {
            (bool ok,) = msg.sender.call{value: excess}("");
            if (!ok) revert EthTransferFailed();
            emit ExcessRefunded(msg.sender, excess);
        }
    }

    /// @notice Before the launch, a contributor whose registration was actually revoked (wallet or entity) or moved
    ///         to another entity takes their BNB back. Mere expiry does not qualify (StillVerified). Frees the
    ///         entity's USD cap by the amount booked for this wallet.
    function withdrawContribution() external nonReentrant {
        if (launched) revert AlreadyLaunched();
        if (launching) revert LaunchInProgress();
        uint256 amount = contributions[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        if (!_contributorRevoked(msg.sender)) revert StillVerified();

        (bytes32 lei, uint256 usd) = _unbook(msg.sender, amount);

        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
        emit ContributionWithdrawn(msg.sender, lei, amount, usd);
    }

    /// @notice Anyone may cancel the sale before the launch when the creator's registration was revoked (wallet or
    ///         entity), moved to another entity, or lost the OOR-officer role; or when it has been EXPIRED for more
    ///         than `CREATOR_EXPIRY_GRACE` (so a short lapse cannot be used to kill the sale). After that `refund()`
    ///         works immediately for every contributor.
    function cancelIfCreatorRevoked() external nonReentrant {
        if (launching) revert LaunchInProgress();
        if (launched) revert AlreadyLaunched();
        if (launchFailed) revert SaleClosed();
        if (cancelled) revert AlreadyCancelled();
        if (!_creatorCancellable()) revert IssuerStillActive();
        cancelled = true;
        emit SaleCancelled(msg.sender, creator);
    }

    /// @notice Take back a contribution after a cancelled sale, a launch the Portal rejected, or after the deadline
    ///         passed below target. No registry check: revoked contributors still get their BNB back.
    function refund() external nonReentrant {
        if (launched || launching) revert RefundUnavailable();
        if (!cancelled && !launchFailed && (raised == targetRaise || block.timestamp < saleDeadline)) {
            revert RefundUnavailable();
        }

        uint256 amount = contributions[msg.sender];
        if (amount == 0) revert NothingToRefund();
        _unbook(msg.sender, amount);

        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
        emit Refunded(msg.sender, amount);
    }

    function _unbook(address account, uint256 amount) private returns (bytes32 lei, uint256 usd) {
        lei = contributorLei[account];
        usd = contributedUsdOf[account];
        contributions[account] = 0;
        contributedUsdOf[account] = 0;
        delete contributorLei[account];
        raised -= amount;
        uint256 inv = investedUsd[lei];
        investedUsd[lei] = inv > usd ? inv - usd : 0;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Launch and distribution
    // ─────────────────────────────────────────────────────────────────────────

    function _launch() private {
        IPortalTypes.CreateTaxTokenParams memory p = _buildParams();
        Distribution memory dist = Distribution({
            target: DistributionTarget.EXPLICIT,
            strategy: address(this),
            amount: uint128(DISTRIBUTED_TOKEN),
            configData: ""
        });
        IPortalTypes.CreatorBuyParams memory creatorBuy;

        uint256 g = gasleft();
        if (g < MIN_LAUNCH_GAS) revert InsufficientLaunchGas(g, MIN_LAUNCH_GAS);

        launching = true;
        try IPortal(hub).launchTaxTokenV2{value: targetRaise}(p, dist, creatorBuy) returns (
            address token_, address pool_
        ) {
            launching = false;
            launched = true;
            token = token_;
            pool = pool_;
            emit Launched(token_, pool_, targetRaise, POOL_TOKEN);
        } catch (bytes memory reason) {
            // The Portal rejected the launch (e.g. below its liquidity floor). Its state and the BNB are rolled back
            // to this contract; open refunds for everyone instead of locking the raise until the deadline.
            launching = false;
            launchFailed = true;
            emit LaunchFailed(reason);
        }
    }

    /// @inheritdoc IStrategy
    function initializeDistribution(address token_, uint256 amount, bytes calldata, bytes32) external override onlyHub {
        if (!launching || distributionInitialized) revert UnauthorizedDistribution();
        if (token_ == address(0) || amount != DISTRIBUTED_TOKEN) revert InvalidConfig();

        distributionInitialized = true;
        token = token_;

        token_.safeTransferFrom(msg.sender, address(this), amount);
        emit FlapDistributionInitialized(token_, amount);
    }

    /// @notice Claim the caller's share of the distributed half. The caller must be vLEI-active; a revoked
    ///         contributor's tokens stay here until the wallet is verified again.
    function claim() external nonReentrant {
        if (!launched) revert DistributionNotInitialized();
        if (!registry.isActive(msg.sender)) revert NotVerified();

        uint256 entitled = (contributions[msg.sender] * DISTRIBUTED_TOKEN) / targetRaise;
        uint256 amount = entitled - claimed[msg.sender];
        if (amount == 0) revert NothingToClaim();

        claimed[msg.sender] = entitled;
        token.safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Launch parameters (unchanged from MintLauncher)
    // ─────────────────────────────────────────────────────────────────────────

    function _buildParams() private view returns (IPortalTypes.CreateTaxTokenParams memory p) {
        p.name = name;
        p.symbol = symbol;
        p.meta = meta;
        p.totalSupply = TOTAL_SUPPLY;
        p.salt = launchSalt;
        p.quoteToken = address(0);
        p.dexId = 0;
        p.poolQuote = targetRaise;
        p.poolToken = POOL_TOKEN;
        p.buyTaxRate = 300;
        p.sellTaxRate = 500;
        p.taxDuration = 30 days;
        p.antiFarmerDuration = 1 days;
        p.feeConfigs = _feeConfigs();
        p.antiSniperMode = 0;
        p.exemptWindow = 0;
        p.exemptAddrs = new address[](0);
        p.creatorBuyQuote = 0;
        (p.extensionID, p.extensionData) = LaunchExtensionHelper.encodeCreator(creator);
        p.commissionReceiver = address(0); // no developer commission (Flap track rule)
    }

    function _feeConfigs() private pure returns (IPortalTypes.FeeConfig[] memory fees) {
        fees = new IPortalTypes.FeeConfig[](3);
        fees[0] = IPortalTypes.FeeConfig({feeType: IPortalTypes.FeeSlotType.DEFLATION, bps: 1000, configData: ""});
        fees[1] = IPortalTypes.FeeConfig({feeType: IPortalTypes.FeeSlotType.LP_BPS, bps: 1500, configData: ""});
        fees[2] = IPortalTypes.FeeConfig({
            feeType: IPortalTypes.FeeSlotType.DIVIDEND,
            bps: 7500,
            configData: abi.encode(
                IPortalTypes.FeeConfigDividend({dividendToken: address(0), minimumShareBalance: TOTAL_SUPPLY / 1000})
            )
        });
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Price
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Staleness bound, read live from the factory (admin-configurable there).
    function maxPriceAge() public view returns (uint256) {
        return IVLEILauncherFactoryConfig(factory).maxPriceAge();
    }

    /// @dev Reverts InvalidPrice / StalePrice. Returns USD per 1 BNB, 18 decimals.
    function _priceStrict() internal view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = priceFeed.latestRoundData();
        if (answer <= 0) revert InvalidPrice();
        if (updatedAt > block.timestamp || block.timestamp - updatedAt > maxPriceAge()) revert StalePrice();
        return (uint256(answer) * 1e18) / (10 ** priceFeed.decimals());
    }

    /// @dev Never reverts. 0 when the feed call fails, the answer is invalid or the price is stale.
    function _priceSoft() internal view returns (uint256 price, uint256 updatedAt) {
        try priceFeed.latestRoundData() returns (uint80, int256 answer, uint256, uint256 upd, uint80) {
            updatedAt = upd;
            if (answer <= 0 || upd > block.timestamp) return (0, upd);
            uint256 age;
            try IVLEILauncherFactoryConfig(factory).maxPriceAge() returns (uint256 a) {
                age = a;
            } catch {
                return (0, upd);
            }
            if (block.timestamp - upd > age) return (0, upd);
            try priceFeed.decimals() returns (uint8 dec) {
                price = (uint256(answer) * 1e18) / (10 ** dec);
            } catch {
                return (0, upd);
            }
        } catch {
            return (0, 0);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Views (UI-facing: no-arg or single-address, never revert)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice 0 Raising, 1 Launched, 2 Failed (deadline passed below target), 3 Cancelled.
    function status() public view returns (uint8) {
        if (launched) return STATUS_LAUNCHED;
        if (cancelled) return STATUS_CANCELLED;
        if (launchFailed || block.timestamp >= saleDeadline) return STATUS_FAILED;
        return STATUS_RAISING;
    }

    /// @notice Whether the creator is still an active OOR officer of the entity the sale was created for.
    function creatorActive() external view returns (bool) {
        return _creatorActive();
    }

    function _creatorActive() internal view returns (bool) {
        return registry.canLaunch(creator) && registry.leiHashOf(creator) == creatorLei;
    }

    /// @dev Revoked, moved to another entity, downgraded, or expired for longer than the grace period.
    function _creatorCancellable() internal view returns (bool) {
        IVLEIRegistryDetails r = IVLEIRegistryDetails(address(registry));
        IVLEIRegistryDetails.Registration memory reg = r.getRegistration(creator);
        if (r.walletRevoked(creator) || r.entityRevoked(creatorLei)) return true;
        if (reg.leiHash != creatorLei || reg.role < ROLE_OOR_OFFICER) return true;
        return block.timestamp >= uint256(reg.expiresAt) + CREATOR_EXPIRY_GRACE;
    }

    /// @dev Actually revoked (wallet or entity) or re-registered under another entity. Expiry alone is not enough.
    function _contributorRevoked(address account) internal view returns (bool) {
        IVLEIRegistryDetails r = IVLEIRegistryDetails(address(registry));
        bytes32 lei = contributorLei[account];
        if (r.walletRevoked(account) || r.entityRevoked(lei)) return true;
        return registry.leiHashOf(account) != lei;
    }

    /// @notice USD per 1 BNB, 18 decimals. 0 when the feed is invalid or stale.
    function bnbUsdPrice() external view returns (uint256 price) {
        (price,) = _priceSoft();
    }

    /// @notice Timestamp of the feed's latest answer (0 when the feed call fails).
    function priceUpdatedAt() external view returns (uint256 updatedAt) {
        try priceFeed.latestRoundData() returns (uint80, int256, uint256, uint256 upd, uint80) {
            updatedAt = upd;
        } catch {}
    }

    /// @notice 0 none, 1 active, 2 expired, 3 wallet revoked, 4 entity revoked.
    function vleiStatusOf(address wallet) external view returns (uint8) {
        IVLEIRegistryDetails r = IVLEIRegistryDetails(address(registry));
        IVLEIRegistryDetails.Registration memory reg = r.getRegistration(wallet);
        if (reg.role == 0) return VLEI_NONE;
        if (r.entityRevoked(reg.leiHash)) return VLEI_ENTITY_REVOKED;
        if (r.walletRevoked(wallet)) return VLEI_WALLET_REVOKED;
        if (block.timestamp >= reg.expiresAt) return VLEI_EXPIRED;
        return VLEI_ACTIVE;
    }

    /// @notice Registry role: 0 none, 1 ECR, 2 OOR, 3 OOR officer.
    function vleiRoleOf(address wallet) external view returns (uint8) {
        return IVLEIRegistryDetails(address(registry)).getRegistration(wallet).role;
    }

    /// @notice Expiry of the wallet's registration (unix seconds, 0 if none).
    function vleiExpiresAt(address wallet) external view returns (uint256) {
        return IVLEIRegistryDetails(address(registry)).getRegistration(wallet).expiresAt;
    }

    function contributionOf(address account) external view returns (uint256) {
        return contributions[account];
    }

    /// @notice Tokens `account` can claim now (0 before the launch).
    function claimableOf(address account) external view returns (uint256) {
        if (!launched) return 0;
        uint256 entitled = (contributions[account] * DISTRIBUTED_TOKEN) / targetRaise;
        return entitled - claimed[account];
    }

    /// @notice USD (18 dp) the wallet's entity may still contribute. 0 if the wallet is not active.
    function remainingCapUsd(address wallet) public view returns (uint256) {
        if (!registry.isActive(wallet)) return 0;
        uint256 inv = investedUsd[registry.leiHashOf(wallet)];
        return inv >= capUsdPerEntity ? 0 : capUsdPerEntity - inv;
    }

    // ── Extra views (frontend / scripts) ────────────────────────────────────

    /// @notice USD value (18 dp) of `bnbAmount`, exactly as `contribute` books it. Reverts if the price is invalid.
    function quoteUsd(uint256 bnbAmount) external view returns (uint256) {
        return (bnbAmount * _priceStrict()) / 1e18;
    }

    /// @notice Largest BNB amount `wallet` can contribute now (0 if not raising, inactive, or no valid price).
    function maxContribution(address wallet) external view returns (uint256 bnb) {
        if (status() != STATUS_RAISING || launching) return 0;
        uint256 rem = remainingCapUsd(wallet);
        (uint256 price,) = _priceSoft();
        if (rem == 0 || price == 0) return 0;
        bnb = (rem * 1e18) / price;
        uint256 left = targetRaise - raised;
        if (bnb > left) bnb = left;
    }

    function saleInfo()
        external
        view
        returns (
            uint8 status_,
            uint256 raised_,
            uint256 targetRaise_,
            uint256 saleDeadline_,
            uint256 capUsdPerEntity_,
            address token_,
            address pool_,
            address creator_
        )
    {
        return (status(), raised, targetRaise, saleDeadline, capUsdPerEntity, token, pool, creator);
    }
}
