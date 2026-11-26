// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPortalTypes, IPortal} from "src/flap/IPortal.sol";
import {LauncherBase} from "src/flap/LauncherBase.sol";
import {Distribution, DistributionTarget} from "src/flap/Distribution.sol";
import {IStrategy} from "src/flap/IStrategy.sol";
import {LaunchExtensionHelper} from "src/flap/LaunchExtensionHelper.sol";
import {LauncherDescription} from "src/flap/LauncherHelper.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {VLEIMintConfig} from "../VLEIMintLauncher.sol";
import {IVLEIRegistry} from "../interfaces/IVLEIRegistry.sol";
import {IVLEIRegistryView} from "../interfaces/IVLEIRegistryView.sol";
import {IPriceFeed} from "../interfaces/IPriceFeed.sol";

/// @dev What a v2 launcher reads from its factory at initialization (and `maxPriceAge` live).
interface IVLEILauncherFactoryV2Config {
    function registry() external view returns (IVLEIRegistry);
    function priceFeed() external view returns (IPriceFeed);
    function maxPriceAge() external view returns (uint256);
    function quoteToken() external view returns (address);
}

/// @title VLEILauncherBaseV2
/// @notice Shared vLEI-gated contribution round for the v2 launchers (`VLEIMintLauncherV2`, `VLEIMintVaultLauncherV2`).
///         Same rules as v1 `VLEIMintLauncher` (gate, per-entity cap, refunds, cancel, withdraw, gated claim, try/catch
///         launch, `MIN_LAUNCH_GAS`), plus a quote asset fixed by the factory:
///
///           quoteToken == address(0)  native BNB. Identical to v1: `contribute()` is payable, the cap is in USD valued
///                                     with the Atlas BNB/USD feed, excess over the target is sent back.
///           quoteToken != address(0)  an 18-decimal ERC20 (e.g. Flap's mock USDT). `contribute()` takes no value and
///                                     pulls min(allowance, balance, target - raised, entity cap left) with
///                                     `transferFrom`; `contributeAmount(amount)` pulls an exact amount (clamped to the
///                                     target). The cap and `minTargetUsd` are in quote units, 1 quote = $1 (no price
///                                     feed on this path). Refunds / withdrawals pay back in the quote token. The
///                                     launch approves the Portal for `poolQuote` and sends `value = 0`.
///
///         Variants only differ in the tax fee slots (`_feeConfigs`), display texts, and vault wiring (hooks).
/// @dev Deployed behind ERC1967 beacon proxies by a `VLEILauncherFactoryBaseV2`; the Flap Guardian is the only
///      upgrade path. v1 contracts are kept unchanged (their deployed bytecode is reproducible from source).
abstract contract VLEILauncherBaseV2 is LauncherBase, Initializable, ReentrancyGuard, IStrategy {
    using SafeERC20 for IERC20;

    uint256 public constant TOTAL_SUPPLY = 1_000_000 ether;
    uint256 public constant POOL_TOKEN = TOTAL_SUPPLY / 2;
    uint256 internal constant DISTRIBUTED_TOKEN = TOTAL_SUPPLY - POOL_TOKEN;

    /// @notice Longest allowed contribution window.
    uint256 public constant MAX_SALE_DURATION = 30 days;
    /// @notice How long after the creator's registration EXPIRES (without a revocation) anyone may cancel.
    uint256 public constant CREATOR_EXPIRY_GRACE = 7 days;
    /// @notice Gas that must be left when the Portal launch is attempted (63/64 rule guard).
    uint256 public constant MIN_LAUNCH_GAS = 7_000_000;
    /// @notice USD value (18 dp) of one whole ERC20 quote token. ERC20 quotes are treated as $1 stablecoins.
    uint256 public constant ERC20_QUOTE_USD = 1e18;
    uint8 internal constant ROLE_OOR_OFFICER = 3;

    /// @notice The only factory allowed to initialize proxies of this implementation.
    address public immutable factory;

    uint8 public constant STATUS_RAISING = 0;
    uint8 public constant STATUS_LAUNCHED = 1;
    uint8 public constant STATUS_FAILED = 2;
    uint8 public constant STATUS_CANCELLED = 3;

    uint8 public constant VLEI_NONE = 0;
    uint8 public constant VLEI_ACTIVE = 1;
    uint8 public constant VLEI_EXPIRED = 2;
    uint8 public constant VLEI_WALLET_REVOKED = 3;
    uint8 public constant VLEI_ENTITY_REVOKED = 4;

    // ── MintLauncher state ──────────────────────────────────────────────────
    address public hub;
    address public creator;
    bytes32 public launchSalt;
    /// @notice Quote amount (wei of the quote asset) to raise; also the pool's quote side.
    uint256 public targetRaise;
    uint256 public saleDeadline;
    string public name;
    string public symbol;
    string public meta;
    uint256 public raised;
    mapping(address account => uint256 amount) public contributions;
    bool public launched;
    /// @notice True only while the Portal launch call runs (a paired vault factory reads it).
    bool public launching;
    bool internal distributionInitialized;
    address public token;
    address public pool;
    mapping(address account => uint256 amount) public claimed;

    // ── vLEI state ──────────────────────────────────────────────────────────
    IVLEIRegistry public registry;
    /// @notice BNB/USD feed (native quote only; address(0) for an ERC20 quote).
    IPriceFeed public priceFeed;
    /// @notice Per-entity cap: USD (18 dp). For an ERC20 quote, quote units (1 quote = $1).
    uint256 public capUsdPerEntity;
    bool public cancelled;
    bool public launchFailed;
    bytes32 public creatorLei;
    mapping(bytes32 leiHash => uint256 usd) public investedUsd;
    mapping(address account => uint256 usd) public contributedUsdOf;
    mapping(address account => bytes32 leiHash) public contributorLei;

    /// @notice The quote asset: address(0) = native BNB, otherwise an 18-decimal ERC20. Copied from the factory.
    address public quoteToken;

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
    // ── v2 (ERC20 quote) ──
    /// @notice ERC20 quote: the caller has not approved this launcher for the quote token.
    error NoAllowance();
    /// @notice ERC20 quote: the caller holds none of the quote token.
    error NoQuoteBalance();
    /// @notice ERC20 quote: the caller's entity already used its whole cap.
    error EntityCapReached(uint256 invested, uint256 cap);
    /// @notice ERC20 quote: native value was sent (must be 0).
    error UnexpectedNativeValue(uint256 value);
    /// @notice `contributeAmount` on a native-BNB launcher (use payable `contribute()`).
    error NativeQuote();
    /// @notice The quote token credited more than was requested.
    error QuoteTransferMismatch(uint256 requested, uint256 received);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address factory_) {
        if (factory_ == address(0)) revert InvalidConfig();
        factory = factory_;
        _disableInitializers();
    }

    /// @notice Called once by the factory in the transaction that deploys the proxy. `msg.value` is the salt-lock
    ///         fee (always native BNB, whatever the quote).
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

        IVLEILauncherFactoryV2Config f = IVLEILauncherFactoryV2Config(msg.sender);
        registry = f.registry();
        if (address(registry) == address(0)) revert InvalidConfig();
        address q = f.quoteToken();
        quoteToken = q;
        if (q == address(0)) {
            priceFeed = f.priceFeed();
            if (address(priceFeed) == address(0)) revert InvalidConfig();
        }
        _initVariant(msg.sender);
        creatorLei = registry.leiHashOf(creator_);

        uint256 fee = IPortal(hub_).SALT_LOCK_FEE();
        if (msg.value != fee) revert InvalidConfig();
        IPortal(hub_).lockSalt{value: fee}(c.salt, uint8(IPortalTypes.LaunchKind.DIRECT_V2_POOL_TAX));
    }

    // ── variant hooks ───────────────────────────────────────────────────────

    /// @dev Read variant-specific config from the factory during `initialize`.
    function _initVariant(address factory_) internal virtual {}

    /// @dev Called inside a successful launch, after `token`/`pool` are set.
    function _afterLaunch(address token_) internal virtual {}

    /// @dev The tax split (bps sum 10,000).
    function _feeConfigs() internal view virtual returns (IPortalTypes.FeeConfig[] memory);

    /// @dev titleZh, titleEn, summaryZh, summaryEn.
    function _texts() internal pure virtual returns (string memory, string memory, string memory, string memory);

    function _getHub() internal view override returns (address) {
        return hub;
    }

    function _description() internal view override returns (LauncherDescription memory d) {
        d.name = name;
        d.symbol = symbol;
        d.quoteToken = quoteToken;
        d.targetRaise = targetRaise;
        d.poolTokenRatio = (POOL_TOKEN * 1e18) / TOTAL_SUPPLY;
        (d.titleZh, d.titleEn, d.summaryZh, d.summaryEn) = _texts();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Contribution round
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Contribute. No arguments (Flap launcher UI).
    ///         Native quote: send BNB; only what is still needed to reach `targetRaise` is kept, the rest is returned.
    ///         ERC20 quote: `msg.value` must be 0; pulls min(allowance to this launcher, balance, target - raised,
    ///         entity cap left). Reverts `NoAllowance` / `NoQuoteBalance` / `EntityCapReached` if that is 0.
    ///         The contribution that reaches `targetRaise` also launches.
    function contribute() external payable nonReentrant {
        _requireOpen();
        if (quoteToken == address(0)) {
            _contributeNative();
            return;
        }
        if (msg.value != 0) revert UnexpectedNativeValue(msg.value);
        (bytes32 lei, uint256 invested) = _gate(msg.sender);

        uint256 amount = targetRaise - raised;
        uint256 cap = capUsdPerEntity;
        if (invested >= cap) revert EntityCapReached(invested, cap);
        if (cap - invested < amount) amount = cap - invested;
        IERC20 q = IERC20(quoteToken);
        uint256 allowed = q.allowance(msg.sender, address(this));
        if (allowed == 0) revert NoAllowance();
        if (allowed < amount) amount = allowed;
        uint256 bal = q.balanceOf(msg.sender);
        if (bal == 0) revert NoQuoteBalance();
        if (bal < amount) amount = bal;

        _pullAndBook(lei, invested, amount);
    }

    /// @notice ERC20 quote only: contribute exactly `amount` (clamped to what the target still needs). Needs an
    ///         allowance of at least that much. Reverts `CapExceeded` if it would exceed the entity cap.
    function contributeAmount(uint256 amount) external nonReentrant {
        _requireOpen();
        if (quoteToken == address(0)) revert NativeQuote();
        if (amount == 0) revert ZeroContribution();
        (bytes32 lei, uint256 invested) = _gate(msg.sender);
        uint256 left = targetRaise - raised;
        if (amount > left) amount = left;
        _pullAndBook(lei, invested, amount);
    }

    function _requireOpen() private view {
        if (launching) revert LaunchInProgress();
        if (cancelled) revert SaleIsCancelled();
        if (launched) revert AlreadyLaunched();
        if (launchFailed || block.timestamp >= saleDeadline) revert SaleClosed();
    }

    /// @dev Sender verified, creator active, sender's entity consistent. Returns the entity and what it invested.
    function _gate(address account) private view returns (bytes32 lei, uint256 invested) {
        if (!registry.isActive(account)) revert NotVerified();
        if (!_creatorActive()) revert IssuerNotActive();
        lei = registry.leiHashOf(account);
        bytes32 prior = contributorLei[account];
        if (prior != bytes32(0) && prior != lei) revert EntityMismatch();
        invested = investedUsd[lei];
    }

    function _contributeNative() private {
        if (msg.value == 0) revert ZeroContribution();
        (bytes32 lei, uint256 invested) = _gate(msg.sender);

        uint256 accepted = targetRaise - raised;
        if (msg.value < accepted) accepted = msg.value;
        uint256 excess = msg.value - accepted;

        _book(lei, invested, accepted, _priceStrict());
        if (raised == targetRaise) _launch();

        if (excess > 0) {
            (bool ok,) = msg.sender.call{value: excess}("");
            if (!ok) revert EthTransferFailed();
            emit ExcessRefunded(msg.sender, excess);
        }
    }

    /// @dev Pull `amount` of the ERC20 quote and credit what actually arrived (balance delta).
    function _pullAndBook(bytes32 lei, uint256 invested, uint256 amount) private {
        IERC20 q = IERC20(quoteToken);
        uint256 before = q.balanceOf(address(this));
        q.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = q.balanceOf(address(this)) - before;
        if (received == 0) revert ZeroContribution();
        if (received > amount) revert QuoteTransferMismatch(amount, received);

        _book(lei, invested, received, ERC20_QUOTE_USD);
        if (raised == targetRaise) _launch();
    }

    function _book(bytes32 lei, uint256 invested, uint256 accepted, uint256 price) private {
        uint256 usd = (accepted * price) / 1e18;
        if (invested + usd > capUsdPerEntity) revert CapExceeded(invested, usd, capUsdPerEntity);
        contributorLei[msg.sender] = lei;
        investedUsd[lei] = invested + usd;
        contributedUsdOf[msg.sender] += usd;
        raised += accepted;
        contributions[msg.sender] += accepted;
        emit Contributed(msg.sender, lei, accepted, usd, price);
    }

    /// @notice Before the launch, a contributor whose registration was actually revoked (wallet or entity) or moved
    ///         to another entity takes its contribution back (in the quote asset). Expiry alone: StillVerified.
    function withdrawContribution() external nonReentrant {
        if (launched) revert AlreadyLaunched();
        if (launching) revert LaunchInProgress();
        uint256 amount = contributions[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        if (!_contributorRevoked(msg.sender)) revert StillVerified();

        (bytes32 lei, uint256 usd) = _unbook(msg.sender, amount);
        _pay(msg.sender, amount);
        emit ContributionWithdrawn(msg.sender, lei, amount, usd);
    }

    /// @notice Anyone may cancel before the launch when the creator was revoked, moved entity, lost the officer role,
    ///         or has been expired for more than `CREATOR_EXPIRY_GRACE`.
    function cancelIfCreatorRevoked() external nonReentrant {
        if (launching) revert LaunchInProgress();
        if (launched) revert AlreadyLaunched();
        if (launchFailed) revert SaleClosed();
        if (cancelled) revert AlreadyCancelled();
        if (!_creatorCancellable()) revert IssuerStillActive();
        cancelled = true;
        emit SaleCancelled(msg.sender, creator);
    }

    /// @notice Take back a contribution (in the quote asset) after a cancel, a rejected launch, or a missed deadline.
    function refund() external nonReentrant {
        if (launched || launching) revert RefundUnavailable();
        if (!cancelled && !launchFailed && (raised == targetRaise || block.timestamp < saleDeadline)) {
            revert RefundUnavailable();
        }
        uint256 amount = contributions[msg.sender];
        if (amount == 0) revert NothingToRefund();
        _unbook(msg.sender, amount);
        _pay(msg.sender, amount);
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

    function _pay(address to, uint256 amount) private {
        if (quoteToken == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert EthTransferFailed();
        } else {
            IERC20(quoteToken).safeTransfer(to, amount);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Launch and distribution
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Native: `value = poolQuote`. ERC20: approve the Portal for `poolQuote` (creatorBuyQuote is 0) and send
    ///      `value = 0`; the allowance is cleared afterwards whatever the outcome.
    function _launch() private {
        IPortalTypes.CreateTaxTokenParams memory p = _buildParams();
        Distribution memory dist = Distribution({
            target: DistributionTarget.EXPLICIT,
            strategy: address(this),
            amount: uint128(DISTRIBUTED_TOKEN),
            configData: ""
        });
        IPortalTypes.CreatorBuyParams memory creatorBuy;

        address q = quoteToken;
        uint256 value = targetRaise;
        if (q != address(0)) {
            IERC20(q).forceApprove(hub, targetRaise);
            value = 0;
        }

        uint256 g = gasleft();
        if (g < MIN_LAUNCH_GAS) revert InsufficientLaunchGas(g, MIN_LAUNCH_GAS);

        launching = true;
        try IPortal(hub).launchTaxTokenV2{value: value}(p, dist, creatorBuy) returns (address token_, address pool_) {
            launching = false;
            launched = true;
            token = token_;
            pool = pool_;
            emit Launched(token_, pool_, targetRaise, POOL_TOKEN);
            _afterLaunch(token_);
        } catch (bytes memory reason) {
            // Portal state and funds roll back to this contract; open refunds for everyone.
            launching = false;
            launchFailed = true;
            emit LaunchFailed(reason);
        }
        if (q != address(0) && IERC20(q).allowance(address(this), hub) != 0) IERC20(q).forceApprove(hub, 0);
    }

    /// @inheritdoc IStrategy
    function initializeDistribution(address token_, uint256 amount, bytes calldata, bytes32) external override onlyHub {
        if (!launching || distributionInitialized) revert UnauthorizedDistribution();
        if (token_ == address(0) || amount != DISTRIBUTED_TOKEN) revert InvalidConfig();
        distributionInitialized = true;
        token = token_;
        IERC20(token_).safeTransferFrom(msg.sender, address(this), amount);
        emit FlapDistributionInitialized(token_, amount);
    }

    /// @notice Claim the caller's share of the distributed half. Caller must be vLEI-active.
    function claim() external nonReentrant {
        if (!launched) revert DistributionNotInitialized();
        if (!registry.isActive(msg.sender)) revert NotVerified();
        uint256 entitled = (contributions[msg.sender] * DISTRIBUTED_TOKEN) / targetRaise;
        uint256 amount = entitled - claimed[msg.sender];
        if (amount == 0) revert NothingToClaim();
        claimed[msg.sender] = entitled;
        IERC20(token).safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    function _buildParams() private view returns (IPortalTypes.CreateTaxTokenParams memory p) {
        p.name = name;
        p.symbol = symbol;
        p.meta = meta;
        p.totalSupply = TOTAL_SUPPLY;
        p.salt = launchSalt;
        p.quoteToken = quoteToken;
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
        p.commissionReceiver = address(0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Price
    // ─────────────────────────────────────────────────────────────────────────

    function maxPriceAge() public view returns (uint256) {
        return IVLEILauncherFactoryV2Config(factory).maxPriceAge();
    }

    /// @dev USD per 1 quote (18 dp). ERC20: fixed `ERC20_QUOTE_USD`. Native: feed, reverts InvalidPrice/StalePrice.
    function _priceStrict() internal view returns (uint256) {
        if (quoteToken != address(0)) return ERC20_QUOTE_USD;
        (, int256 answer,, uint256 updatedAt,) = priceFeed.latestRoundData();
        if (answer <= 0) revert InvalidPrice();
        if (updatedAt > block.timestamp || block.timestamp - updatedAt > maxPriceAge()) revert StalePrice();
        return (uint256(answer) * 1e18) / (10 ** priceFeed.decimals());
    }

    /// @dev Never reverts. ERC20: (1e18, now). Native: 0 when the feed fails, is invalid or stale.
    function _priceSoft() internal view returns (uint256 price, uint256 updatedAt) {
        if (quoteToken != address(0)) return (ERC20_QUOTE_USD, block.timestamp);
        try priceFeed.latestRoundData() returns (uint80, int256 answer, uint256, uint256 upd, uint80) {
            updatedAt = upd;
            if (answer <= 0 || upd > block.timestamp) return (0, upd);
            uint256 age;
            try IVLEILauncherFactoryV2Config(factory).maxPriceAge() returns (uint256 a) {
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

    /// @notice 0 Raising, 1 Launched, 2 Failed (deadline passed below target, or the Portal rejected the launch),
    ///         3 Cancelled.
    function status() public view returns (uint8) {
        if (launched) return STATUS_LAUNCHED;
        if (cancelled) return STATUS_CANCELLED;
        if (launchFailed || block.timestamp >= saleDeadline) return STATUS_FAILED;
        return STATUS_RAISING;
    }

    function creatorActive() external view returns (bool) {
        return _creatorActive();
    }

    function _creatorActive() internal view returns (bool) {
        return registry.canLaunch(creator) && registry.leiHashOf(creator) == creatorLei;
    }

    function _creatorCancellable() internal view returns (bool) {
        IVLEIRegistryView r = IVLEIRegistryView(address(registry));
        IVLEIRegistryView.Registration memory reg = r.getRegistration(creator);
        if (r.walletRevoked(creator) || r.entityRevoked(creatorLei)) return true;
        if (reg.leiHash != creatorLei || reg.role < ROLE_OOR_OFFICER) return true;
        return block.timestamp >= uint256(reg.expiresAt) + CREATOR_EXPIRY_GRACE;
    }

    function _contributorRevoked(address account) internal view returns (bool) {
        IVLEIRegistryView r = IVLEIRegistryView(address(registry));
        bytes32 lei = contributorLei[account];
        if (r.walletRevoked(account) || r.entityRevoked(lei)) return true;
        return registry.leiHashOf(account) != lei;
    }

    /// @notice USD per 1 unit of the QUOTE asset, 18 dp. Native: Atlas BNB/USD (0 if invalid/stale).
    ///         ERC20 quote: always 1e18 (the quote is treated as $1; the name is kept for the UI ABI).
    function bnbUsdPrice() external view returns (uint256 price) {
        (price,) = _priceSoft();
    }

    /// @notice Native: timestamp of the feed's latest answer (0 if the call fails). ERC20 quote: `block.timestamp`
    ///         (fixed price, never stale).
    function priceUpdatedAt() external view returns (uint256 updatedAt) {
        if (quoteToken != address(0)) return block.timestamp;
        try priceFeed.latestRoundData() returns (uint80, int256, uint256, uint256 upd, uint80) {
            updatedAt = upd;
        } catch {}
    }

    function vleiStatusOf(address wallet) external view returns (uint8) {
        IVLEIRegistryView r = IVLEIRegistryView(address(registry));
        IVLEIRegistryView.Registration memory reg = r.getRegistration(wallet);
        if (reg.role == 0) return VLEI_NONE;
        if (r.entityRevoked(reg.leiHash)) return VLEI_ENTITY_REVOKED;
        if (r.walletRevoked(wallet)) return VLEI_WALLET_REVOKED;
        if (block.timestamp >= reg.expiresAt) return VLEI_EXPIRED;
        return VLEI_ACTIVE;
    }

    function vleiRoleOf(address wallet) external view returns (uint8) {
        return IVLEIRegistryView(address(registry)).getRegistration(wallet).role;
    }

    function vleiExpiresAt(address wallet) external view returns (uint256) {
        return IVLEIRegistryView(address(registry)).getRegistration(wallet).expiresAt;
    }

    function contributionOf(address account) external view returns (uint256) {
        return contributions[account];
    }

    function claimableOf(address account) external view returns (uint256) {
        if (!launched) return 0;
        uint256 entitled = (contributions[account] * DISTRIBUTED_TOKEN) / targetRaise;
        return entitled - claimed[account];
    }

    /// @notice USD (18 dp; ERC20 quote: quote units) the wallet's entity may still contribute. 0 if inactive.
    function remainingCapUsd(address wallet) public view returns (uint256) {
        if (!registry.isActive(wallet)) return 0;
        uint256 inv = investedUsd[registry.leiHashOf(wallet)];
        return inv >= capUsdPerEntity ? 0 : capUsdPerEntity - inv;
    }

    /// @notice ERC20 quote: `allowance(account, this)`. Native: type(uint256).max (no approval needed).
    function allowanceOf(address account) external view returns (uint256) {
        if (quoteToken == address(0)) return type(uint256).max;
        try IERC20(quoteToken).allowance(account, address(this)) returns (uint256 a) {
            return a;
        } catch {
            return 0;
        }
    }

    /// @notice The account's balance of the quote asset (native BNB balance for a native launcher).
    function quoteBalanceOf(address account) external view returns (uint256) {
        if (quoteToken == address(0)) return account.balance;
        try IERC20(quoteToken).balanceOf(account) returns (uint256 b) {
            return b;
        } catch {
            return 0;
        }
    }

    // ── Extra views (frontend / scripts) ────────────────────────────────────

    /// @notice USD value (18 dp) of `amount` of the quote, exactly as a contribution books it.
    function quoteUsd(uint256 amount) external view returns (uint256) {
        return (amount * _priceStrict()) / 1e18;
    }

    /// @notice Largest quote amount `wallet` may contribute now, from the cap and the target only (ignores its
    ///         allowance and balance). Use it as the amount to approve. 0 if not raising, inactive or no price.
    function maxContribution(address wallet) public view returns (uint256 amount) {
        if (status() != STATUS_RAISING || launching) return 0;
        uint256 rem = remainingCapUsd(wallet);
        (uint256 price,) = _priceSoft();
        if (rem == 0 || price == 0) return 0;
        amount = (rem * 1e18) / price;
        uint256 left = targetRaise - raised;
        if (amount > left) amount = left;
    }

    /// @notice ERC20 quote: what a no-arg `contribute()` by `wallet` would pull now (also bounded by allowance and
    ///         balance). Native: same as `maxContribution`.
    function previewContribute(address wallet) external view returns (uint256 amount) {
        amount = maxContribution(wallet);
        if (quoteToken == address(0) || amount == 0) return amount;
        IERC20 q = IERC20(quoteToken);
        try q.allowance(wallet, address(this)) returns (uint256 a) {
            if (a < amount) amount = a;
        } catch {
            return 0;
        }
        try q.balanceOf(wallet) returns (uint256 b) {
            if (b < amount) amount = b;
        } catch {
            return 0;
        }
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
