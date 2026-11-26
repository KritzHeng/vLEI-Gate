import { parseAbi } from "viem";

// ═══════════════════════════════════════════════════════════════════════════
// CONTRACT INTERFACE (ABI block): the single place to reconcile with contracts/.
//
//   vleiDividendVaultAbi <- contracts/src/v2/vault/VLEIDividendVaultV2.sol (target: context.vaultAddress)
//                           compiled ABI: contracts/out/VLEIDividendVaultV2.sol/VLEIDividendVaultV2.json
//
// The token ABI is the SDK's standard erc20Abi (balanceOf / allowance / approve); it is not copied here.
// Errors are listed so the SDK's viem client can decode custom-error names from failed simulations.
// Selectors (cast sig): NotVerified 0xa95362b5, EntityMismatch 0x2d8d9b2b, ZeroAmount 0x1f2a2005,
// BelowMinStake 0x9be9d80a, InsufficientStake 0x45be0a26, NothingToClaim 0x969bf728, NotEvictable 0x8480448c,
// QuoteTransferFailed 0x4773de48, SafeERC20FailedOperation 0x5274afe7.
// ═══════════════════════════════════════════════════════════════════════════

export const vleiDividendVaultAbi = parseAbi([
  // ── pool views (no args) ──
  "function taxToken() view returns (address)",
  "function quoteToken() view returns (address)",
  "function totalStaked() view returns (uint256)",
  "function totalRevenue() view returns (uint256)",
  "function totalClaimed() view returns (uint256)",
  "function totalForfeited() view returns (uint256)",
  "function undistributed() view returns (uint256)",
  "function MIN_STAKE() view returns (uint256)",
  "function HELD_RELEASE_MIN_STAKE() view returns (uint256)",
  // ── per-account views (one address arg) ──
  "function stakedOf(address account) view returns (uint256)",
  "function pendingRewards(address account) view returns (uint256)",
  "function claimable(address account) view returns (uint256)",
  "function canClaim(address account) view returns (bool)",
  "function evictable(address account) view returns (bool)",
  "function isEarning(address account) view returns (bool)",
  // ── actions ──
  "function stake(uint256 amount)",
  "function unstake(uint256 amount)",
  "function claim() returns (uint256 amount)",
  "function evict(address account)",
  "function sync()",
  // ── custom errors ──
  "error NotVerified()",
  "error EntityMismatch()",
  "error ZeroAmount()",
  "error BelowMinStake(uint256 balance, uint256 minimum)",
  "error InsufficientStake(uint256 requested, uint256 staked)",
  "error NothingToClaim()",
  "error NotEvictable(address account)",
  "error QuoteTransferFailed()",
  "error SafeERC20FailedOperation(address token)",
]);

/** Custom-error name -> i18n key, used to explain a failed simulation. */
export const VAULT_ERROR_KEYS: readonly (readonly [string, string])[] = [
  ["NotVerified", "errors.notVerified"],
  ["EntityMismatch", "errors.entityMismatch"],
  ["ZeroAmount", "errors.zeroAmount"],
  ["BelowMinStake", "errors.belowMinStake"],
  ["InsufficientStake", "errors.insufficientStake"],
  ["NothingToClaim", "errors.nothingToClaim"],
  ["NotEvictable", "errors.notEvictable"],
  ["QuoteTransferFailed", "errors.quoteTransfer"],
  ["SafeERC20FailedOperation", "errors.quoteTransfer"],
];
