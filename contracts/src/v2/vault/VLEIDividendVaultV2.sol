// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {DirectLaunchVaultBase} from "src/flap/DirectLaunchVaultBase.sol";
import {VaultUISchema, VaultMethodSchema, FieldDescriptor, ApproveAction} from "src/flap/IVaultSchemas.sol";

import {IVLEIRegistry} from "../../interfaces/IVLEIRegistry.sol";
import {IVLEIRegistryView} from "../../interfaces/IVLEIRegistryView.sol";

/// @notice What the vault reads from the launcher that created it.
interface IVLEIVaultLauncherV2 {
    function registry() external view returns (IVLEIRegistry);
}

/// @title VLEIDividendVaultV2
/// @notice Gated-yield vault for a vLEI-gated Flap Pool Launch. The launch's VAULT fee slot (75% of the token's
///         tax) pays the launch's QUOTE asset here (native BNB or an ERC20 such as USDT), and the vault pays it out ONLY to verified legal entities: wallets that are
///         active in `VLEIRegistry` and have staked the token in this vault.
///
///         Anyone can trade the token; first-round allocation AND yield go only to verified legal entities.
///
///   Money flow
///   ──────────
///     DEX trade ─► token tax ─► TaxProcessor.dispatch ─► receive() ─► accRewardPerShare += Δ / totalStaked
///     staker: claim() ─► owed quote          (caller must be vLEI-active)
///
///   Why staking: the token is Flap's `FlapDirectTaxToken`, so we cannot hook its transfers to track balances.
///   Holders who want yield move their tokens into this vault; the vault then knows every earning balance exactly
///   and can gate it on `isActive` at stake and claim time. The vault takes no fee: 100% of its revenue goes to
///   stakers. Principal is never gated: `unstake` always returns the tokens.
///
///   Gating rules
///   ────────────
///     - `stake` requires `registry.isActive(msg.sender)`. The stake is bound to the wallet's leiHash.
///     - `claim` requires `isActive` and the same leiHash. An EXPIRED staker keeps earning but cannot claim until
///       it renews its attestation.
///     - A staker is EVICTABLE when its wallet or entity is revoked, it was re-registered under another LEI
///       (or without a role), or its registration has been expired for more than `EXPIRY_GRACE`.
///       Anyone may call `evict(account)`: the tokens go back to the account, it stops earning, and its unclaimed
///       rewards are FORFEITED and redistributed pro rata to the remaining stakers. Remaining stakers therefore
///       have a direct incentive to evict, and the revocation watcher does it right after `revokeWallet` /
///       `revokeEntity`.
///     - A revoked staker that calls `unstake` gets its whole stake back and forfeits its rewards (same as evict).
///
///   Accounting (gas-safe for any number of stakers, no loops)
///   ─────────────────────────────────────────────────────────
///     Pull-based dividends per share: `accRewardPerShare` (scaled by 1e36) grows by `revenue × 1e36 / totalStaked`
///     on every revenue lump; each staker checkpoints `amount × acc − rewardDebt` into `owed` before its stake
///     changes. Revenue is recognized by balance delta (`balance − accountedBalance`), per Flap's spec, and every
///     quote outflow lowers the baseline. Native: `receive()` only touches storage. ERC20: the TaxProcessor transfers
///     the tokens and then wakes the vault with a zero-value call (`receive()`), which reads `balanceOf`; `sync()`
///     (anyone) and every stake / unstake / claim / evict also sync, so revenue is never lost if a wake is missed.
///     Revenue that arrives while nothing is staked is held in `undistributed` and paid to the stakers at the next
///     sync. A minimum position (`MIN_STAKE`) keeps the per-share math far from overflow.
///
/// @dev v2: the revenue asset is `quoteToken` (address(0) = native BNB). Deployed per launch as an ERC1967 beacon
///      proxy by `VLEIDividendVaultFactoryV2`; only the
///      Flap Guardian can upgrade (through the factory). No privileged function exists on the vault itself.
contract VLEIDividendVaultV2 is DirectLaunchVaultBase, Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Strings for uint256;

    /// @notice Smallest non-zero position (1 token). Keeps `totalStaked >= 1e18` whenever it is non-zero.
    uint256 public constant MIN_STAKE = 1e18;
    /// @notice An expired (not revoked) staker becomes evictable this long after its registration's expiry.
    uint256 public constant EXPIRY_GRACE = 7 days;
    /// @notice Revenue held while nothing was staked (or forfeited with no stakers left) is released only once at
    ///         least this much token (1% of a 1M supply) is staked, so a single 1-token staker cannot sweep it.
    uint256 public constant HELD_RELEASE_MIN_STAKE = 10_000e18;
    uint256 internal constant PRECISION = 1e36;

    /// @notice The only factory allowed to initialize proxies of this implementation.
    address public immutable factory;

    /// @notice The launch's tax token (the staking asset).
    address public taxToken;
    /// @notice The `VLEIMintVaultLauncher` that launched the token.
    address public launcher;
    IVLEIRegistry public registry;
    /// @notice The revenue asset: address(0) = native BNB, otherwise the ERC20 quote of the launch.
    address public quoteToken;

    // ── revenue ──
    /// @notice quote recognized and not yet paid out (balance-delta baseline).
    uint256 public accountedBalance;
    /// @notice Lifetime quote revenue recognized.
    uint256 public totalRevenue;
    /// @notice Lifetime quote paid to stakers.
    uint256 public totalClaimed;
    /// @notice Lifetime quote forfeited by evicted stakers (and redistributed).
    uint256 public totalForfeited;
    /// @notice Revenue / forfeits waiting for stakers (arrived while nothing was staked).
    uint256 public undistributed;
    /// @notice Cumulative quote per staked token, scaled by 1e36.
    uint256 public accRewardPerShare;

    // ── stakes ──
    uint256 public totalStaked;

    struct Staker {
        uint256 amount;
        uint256 rewardDebt;
        uint256 owed;
        bytes32 leiHash;
    }

    mapping(address account => Staker) internal _stakers;

    event RevenueReceived(uint256 amount, uint256 totalRevenue);
    event Distributed(uint256 amount, uint256 accRewardPerShare);
    event Staked(address indexed account, bytes32 indexed leiHash, uint256 amount, uint256 newBalance);
    event Unstaked(address indexed account, uint256 amount, uint256 newBalance);
    event Claimed(address indexed account, uint256 amount);
    event Evicted(address indexed account, address indexed caller, uint256 returned, uint256 forfeited);

    error NotFactory(address caller);
    error ZeroAddress();
    error NotVerified();
    error EntityMismatch();
    error ZeroAmount();
    error BelowMinStake(uint256 balance, uint256 minimum);
    error InsufficientStake(uint256 requested, uint256 staked);
    error NothingToClaim();
    error NotEvictable(address account);
    error QuoteTransferFailed();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address factory_) {
        if (factory_ == address(0)) revert ZeroAddress();
        factory = factory_;
        _disableInitializers();
    }

    /// @notice Called once by the factory in `newVault`, inside the launch transaction. `taxToken_` is the predicted
    ///         token address and has no code yet, so it is not called here.
    function initialize(address taxToken_, address launcher_, address quoteToken_) external initializer {
        if (msg.sender != factory) revert NotFactory(msg.sender);
        if (taxToken_ == address(0) || launcher_ == address(0)) revert ZeroAddress();
        IVLEIRegistry r = IVLEIVaultLauncherV2(launcher_).registry();
        if (address(r) == address(0)) revert ZeroAddress();
        taxToken = taxToken_;
        launcher = launcher_;
        registry = r;
        quoteToken = quoteToken_;
    }

    function version() external pure returns (string memory) {
        return "v2.0.0";
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Revenue
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Wake / revenue entry: native BNB from the TaxProcessor, or its zero-value ping after an ERC20 transfer.
    ///         Never reverts on a wake. BNB sent to an ERC20-quote vault is not revenue (ignored).
    receive() external payable {
        _sync();
    }

    /// @notice Recognize quote revenue that arrived without a wake (e.g. an ERC20 transfer with no ping). Anyone.
    function sync() external {
        _sync();
    }

    function _sync() internal {
        uint256 bal = _quoteBalance();
        uint256 base = accountedBalance;
        if (bal > base) {
            uint256 delta = bal - base;
            accountedBalance = bal;
            totalRevenue += delta;
            emit RevenueReceived(delta, totalRevenue);
            _distribute(delta);
        } else if (undistributed != 0 && totalStaked >= HELD_RELEASE_MIN_STAKE) {
            _distribute(0);
        }
    }

    /// @dev This vault's balance of its revenue asset.
    function _quoteBalance() internal view returns (uint256) {
        address q = quoteToken;
        return q == address(0) ? address(this).balance : IERC20(q).balanceOf(address(this));
    }

    function _payQuote(address to, uint256 amount) internal {
        address q = quoteToken;
        if (q == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert QuoteTransferFailed();
        } else {
            IERC20(q).safeTransfer(to, amount);
        }
    }

    /// @dev Spread `amount` (plus anything held back) over the current stake, or hold it if nothing is staked.
    function _distribute(uint256 amount) internal {
        uint256 staked = totalStaked;
        if (staked == 0) {
            undistributed += amount;
            return;
        }
        uint256 total = amount;
        if (undistributed != 0 && staked >= HELD_RELEASE_MIN_STAKE) {
            total += undistributed;
            undistributed = 0;
        }
        if (total == 0) return;
        accRewardPerShare += (total * PRECISION) / staked;
        emit Distributed(total, accRewardPerShare);
    }

    /// @dev Move what `s` earned since its last checkpoint into `owed`.
    function _checkpoint(Staker storage s) internal {
        uint256 accrued = (s.amount * accRewardPerShare) / PRECISION;
        if (accrued > s.rewardDebt) s.owed += accrued - s.rewardDebt;
        s.rewardDebt = accrued;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Staking
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Stake `amount` of the token to earn the vault's quote revenue. Caller must be vLEI-active. Needs an
    ///         ERC20 approval of `amount` to this vault. The stake is credited by balance delta.
    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (!registry.isActive(msg.sender)) revert NotVerified();
        bytes32 lei = registry.leiHashOf(msg.sender);
        Staker storage s = _stakers[msg.sender];
        // A position (stake OR unclaimed rewards) stays bound to its LEI; a wallet that moved entity must be evicted
        // (forfeiting) before it can stake again, so rewards earned for one entity never leave via another.
        if ((s.amount != 0 || s.owed != 0) && s.leiHash != lei) revert EntityMismatch();

        // Pull first, then settle, so a dispatch triggered by the transfer itself could never be stranded.
        uint256 before = IERC20(taxToken).balanceOf(address(this));
        IERC20(taxToken).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(taxToken).balanceOf(address(this)) - before;
        if (received == 0) revert ZeroAmount();

        _sync();
        _checkpoint(s);

        uint256 newBalance = s.amount + received;
        if (newBalance < MIN_STAKE) revert BelowMinStake(newBalance, MIN_STAKE);
        s.amount = newBalance;
        s.leiHash = lei;
        s.rewardDebt = (newBalance * accRewardPerShare) / PRECISION;
        totalStaked += received;
        emit Staked(msg.sender, lei, received, newBalance);
    }

    /// @notice Take staked tokens back. Never gated on vLEI status. Rewards already earned stay claimable
    ///         (`claim` needs an active registration). If the caller is evictable (revoked), the whole position is
    ///         returned instead and its unclaimed rewards are forfeited, exactly as `evict` would.
    function unstake(uint256 amount) external nonReentrant {
        if (_evictable(msg.sender)) {
            _evict(msg.sender);
            return;
        }
        Staker storage s = _stakers[msg.sender];
        if (amount == 0) revert ZeroAmount();
        if (amount > s.amount) revert InsufficientStake(amount, s.amount);
        uint256 remaining = s.amount - amount;
        if (remaining != 0 && remaining < MIN_STAKE) revert BelowMinStake(remaining, MIN_STAKE);

        _sync();
        _checkpoint(s);
        s.amount = remaining;
        s.rewardDebt = (remaining * accRewardPerShare) / PRECISION;
        totalStaked -= amount;

        IERC20(taxToken).safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount, remaining);
    }

    /// @notice Pay the caller its rewards in the quote asset. Caller must be vLEI-active under the entity it staked for.
    function claim() external nonReentrant returns (uint256 amount) {
        if (!_canClaim(msg.sender)) revert NotVerified();
        Staker storage s = _stakers[msg.sender];
        _sync();
        _checkpoint(s);
        uint256 owed = s.owed;
        // Per-staker floor rounding can credit up to 1 wei more than was distributed; never pay from held revenue.
        uint256 free = accountedBalance - undistributed;
        amount = owed < free ? owed : free;
        if (amount == 0) revert NothingToClaim();

        s.owed = owed - amount;
        accountedBalance -= amount;
        totalClaimed += amount;
        _payQuote(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    /// @notice Remove a revoked staker. Anyone may call. Its tokens go back to it, its unclaimed rewards are
    ///         forfeited and redistributed to the remaining stakers.
    function evict(address account) external nonReentrant {
        if (!_evictable(account)) revert NotEvictable(account);
        _evict(account);
    }

    function _evict(address account) internal {
        Staker storage s = _stakers[account];
        _sync();
        _checkpoint(s);

        uint256 returned = s.amount;
        uint256 forfeited = s.owed;
        totalStaked -= returned;
        delete _stakers[account];

        if (forfeited != 0) {
            totalForfeited += forfeited;
            _distribute(forfeited); // already inside accountedBalance; only its owner changes
        }
        if (returned != 0) IERC20(taxToken).safeTransfer(account, returned);
        emit Evicted(account, msg.sender, returned, forfeited);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Gating
    // ─────────────────────────────────────────────────────────────────────────

    function _canClaim(address account) internal view returns (bool) {
        return registry.isActive(account) && registry.leiHashOf(account) == _stakers[account].leiHash;
    }

    /// @dev Revoked (wallet or entity), re-registered under another LEI / without a role, or expired past the grace.
    function _evictable(address account) internal view returns (bool) {
        Staker storage s = _stakers[account];
        if (s.amount == 0 && s.owed == 0) return false;
        IVLEIRegistryView r = IVLEIRegistryView(address(registry));
        if (r.walletRevoked(account) || r.entityRevoked(s.leiHash)) return true;
        IVLEIRegistryView.Registration memory reg = r.getRegistration(account);
        if (reg.role == 0 || reg.leiHash != s.leiHash) return true;
        // Mere expiry only evicts a live stake (it dilutes others); rewards left after a full unstake wait for renewal.
        return s.amount != 0 && block.timestamp >= uint256(reg.expiresAt) + EXPIRY_GRACE;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Views (UI: no-arg or single-address)
    // ─────────────────────────────────────────────────────────────────────────

    function stakedOf(address account) external view returns (uint256) {
        return _stakers[account].amount;
    }

    function stakerLeiHash(address account) external view returns (bytes32) {
        return _stakers[account].leiHash;
    }

    /// @notice Quote `account` has earned and not claimed, including revenue not yet synced.
    function pendingRewards(address account) public view returns (uint256) {
        Staker storage s = _stakers[account];
        uint256 acc = accRewardPerShare;
        uint256 staked = totalStaked;
        if (staked != 0) {
            uint256 bal = _quoteBalance();
            uint256 fresh = bal > accountedBalance ? bal - accountedBalance : 0;
            uint256 released = fresh + (staked >= HELD_RELEASE_MIN_STAKE ? undistributed : 0);
            acc += (released * PRECISION) / staked;
        }
        uint256 accrued = (s.amount * acc) / PRECISION;
        return s.owed + (accrued > s.rewardDebt ? accrued - s.rewardDebt : 0);
    }

    /// @notice What `claim()` would pay `account` now (0 if it may not claim).
    function claimable(address account) external view returns (uint256) {
        if (!_canClaim(account)) return 0;
        uint256 pending = pendingRewards(account);
        uint256 bal = _quoteBalance();
        uint256 fresh = bal > accountedBalance ? bal - accountedBalance : 0;
        uint256 held = undistributed;
        if (totalStaked == 0) held += fresh;
        else if (totalStaked >= HELD_RELEASE_MIN_STAKE) held = 0;
        uint256 free = bal > held ? bal - held : 0;
        return pending < free ? pending : free;
    }

    function canClaim(address account) external view returns (bool) {
        return _canClaim(account);
    }

    /// @notice Whether anyone may `evict(account)` now.
    function evictable(address account) external view returns (bool) {
        return _evictable(account);
    }

    /// @notice Whether `account`'s stake currently counts toward revenue it can keep.
    function isEarning(address account) external view returns (bool) {
        return _stakers[account].amount != 0 && !_evictable(account);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // IDirectLaunchVault
    // ─────────────────────────────────────────────────────────────────────────

    /// @inheritdoc DirectLaunchVaultBase
    function description() public view override returns (string memory) {
        return string.concat(
            "VLEIDividendVaultV2: 100% of this vault's quote revenue (the token's VAULT tax share) is paid to "
            "holders who stake the token here AND are active in VLEIRegistry ",
            Strings.toHexString(address(registry)),
            ", pro rata to their stake. No fee, no commission, no creator or developer share. Unverified holders "
            "cannot stake; revoked stakers can be evicted by anyone, get their tokens back and forfeit unclaimed "
            "rewards, which go to the remaining stakers. Expired stakers cannot claim until they renew and become evictable "
            "7 days after expiry. Revenue that arrives while nothing is staked is held until at least 10,000 tokens "
            "are staked. Staked principal is never locked. Staked: ",
            totalStaked.toString(),
            " wei of token. Revenue: ",
            totalRevenue.toString(),
            " wei; claimed: ",
            totalClaimed.toString(),
            " wei; forfeited: ",
            totalForfeited.toString(),
            " wei. Quote asset: ",
            quoteToken == address(0) ? "native BNB" : Strings.toHexString(quoteToken),
            "."
        );
    }

    /// @inheritdoc DirectLaunchVaultBase
    function vaultUISchema() public pure override returns (VaultUISchema memory schema) {
        schema.vaultType = "VLEIDividendVaultV2";
        schema.description = "Gated yield: stake the token to earn its tax revenue in the quote asset (BNB or USDT). Only wallets verified as "
            "legal entities (vLEI) may stake and claim; no fee.";
        schema.methods = new VaultMethodSchema[](7);

        schema.methods[0].name = "stake";
        schema.methods[0].description =
        "Stake tokens to earn the quote asset (vLEI-verified wallets only, min 1 token).";
        schema.methods[0].inputs = new FieldDescriptor[](1);
        schema.methods[0].inputs[0] = FieldDescriptor("amount", "uint256", "Tokens to stake", 18);
        schema.methods[0].approvals = new ApproveAction[](1);
        schema.methods[0].approvals[0] = ApproveAction("taxToken", "amount");
        schema.methods[0].isWriteMethod = true;

        schema.methods[1].name = "unstake";
        schema.methods[1].description = "Withdraw staked tokens (never gated).";
        schema.methods[1].inputs = new FieldDescriptor[](1);
        schema.methods[1].inputs[0] = FieldDescriptor("amount", "uint256", "Tokens to withdraw", 18);
        schema.methods[1].isWriteMethod = true;

        schema.methods[2].name = "claim";
        schema.methods[2].description = "Claim your rewards (BNB or USDT) (vLEI-active wallets only).";
        schema.methods[2].isWriteMethod = true;

        schema.methods[3].name = "evict";
        schema.methods[3].description = "Remove a revoked staker; its unclaimed rewards go to the other stakers.";
        schema.methods[3].inputs = new FieldDescriptor[](1);
        schema.methods[3].inputs[0] = FieldDescriptor("account", "address", "Revoked staker", 0);
        schema.methods[3].isWriteMethod = true;

        schema.methods[4].name = "claimable";
        schema.methods[4].description = "Quote (BNB or USDT) the account can claim now.";
        schema.methods[4].inputs = new FieldDescriptor[](1);
        schema.methods[4].inputs[0] = FieldDescriptor("account", "address", "Staker", 0);
        schema.methods[4].outputs = new FieldDescriptor[](1);
        schema.methods[4].outputs[0] = FieldDescriptor("amount", "uint256", "Claimable quote", 18);

        schema.methods[5].name = "stakedOf";
        schema.methods[5].description = "Tokens the account has staked.";
        schema.methods[5].inputs = new FieldDescriptor[](1);
        schema.methods[5].inputs[0] = FieldDescriptor("account", "address", "Staker", 0);
        schema.methods[5].outputs = new FieldDescriptor[](1);
        schema.methods[5].outputs[0] = FieldDescriptor("amount", "uint256", "Staked tokens", 18);

        schema.methods[6].name = "totalRevenue";
        schema.methods[6].description = "Quote revenue recognized so far.";
        schema.methods[6].outputs = new FieldDescriptor[](1);
        schema.methods[6].outputs[0] = FieldDescriptor("amount", "uint256", "Total quote received", 18);
    }
}
