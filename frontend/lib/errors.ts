import {
  BaseError,
  ContractFunctionRevertedError,
  UserRejectedRequestError,
  decodeErrorResult,
  formatUnits,
  type Hex,
} from "viem";
import { allErrorsAbi } from "./abis";

const usd = (v: unknown) => `$${Number(formatUnits(BigInt(v as bigint), 18)).toFixed(2)}`;
/** 18-decimal token amount (quote or launch token). */
const amt = (v: unknown) => Number(formatUnits(BigInt(v as bigint), 18)).toLocaleString(undefined, { maximumFractionDigits: 4 });

const FRIENDLY: Record<string, (args: readonly unknown[]) => string> = {
  // factory (VLEILauncherFactory, reached through Portal.newLauncher)
  CreatorNotAuthorized: (a) =>
    `Not authorized to create a launcher: ${a[0]} needs an active OOR registration with an authorized official role (OOR_OFFICER).`,
  NotHub: (a) => `Only the Flap Portal may call this (caller ${a[0]}).`,
  NotGuardian: (a) => `Only the Flap Guardian may do this (caller ${a[0]}).`,
  TargetBelowMinimum: (a) => `Target raise too small: worth ${usd(a[0])} at the Atlas price, the factory minimum is ${usd(a[1])}.`,
  InvalidMaxPriceAge: () => "maxPriceAge must be between 1 second and 7 days.",
  OwnableUnauthorizedAccount: (a) => `Connected wallet ${a[0]} is not the factory owner.`,
  // launcher (VLEIMintLauncher)
  NotVerified: () => "Not verified: this wallet has no active vLEI registration (never registered, expired, or revoked).",
  IssuerNotActive: () =>
    "The launcher's creator is no longer an active vLEI registration (revoked or expired), so contributions are blocked. Anyone can call cancelIfCreatorRevoked, then refund.",
  IssuerStillActive: () => "cancelIfCreatorRevoked only works once the creator is no longer active in the registry.",
  CapExceeded: (a) =>
    `USD cap exceeded: your entity already contributed ${usd(a[0])}, this contribution is ${usd(a[1])}, the cap per legal entity is ${usd(a[2])}.`,
  EntityMismatch: () =>
    "This wallet's existing position (launcher contribution, or vault stake / unclaimed yield) is bound to a different legal entity (LEI) than the one it is registered to now. In a vault, the old position must be evicted first.",
  StillVerified: () => "withdrawContribution is only for contributors whose vLEI registration is no longer active (before the launch).",
  SaleClosed: () => "The contribution window has closed (deadline passed).",
  SaleIsCancelled: () => "The sale was cancelled because the creator's vLEI was revoked. Use refund.",
  AlreadyCancelled: () => "The sale is already cancelled.",
  AlreadyLaunched: () => "The token has already launched.",
  LaunchInProgress: () => "The launch is in progress.",
  ZeroContribution: () => "Contribution must be greater than zero.",
  NotFactory: (a) => `Only the factory may call this (caller ${a[0]}).`,
  InsufficientLaunchGas: (a) =>
    `This contribution reaches the target and launches the token, which needs more gas (${String(a[0])} left, ${String(a[1])} required). Raise the gas limit.`,
  DistributionNotInitialized: () => "Nothing to claim yet: the token has not launched.",
  NothingToClaim: () => "Nothing to claim for this wallet (launcher: no tokens owed; vault: no yield owed yet).",
  RefundUnavailable: () => "Refund is only available after a cancelled sale, or after the deadline passed below target.",
  NothingToRefund: () => "Nothing to refund for this wallet.",
  NothingToWithdraw: () => "Nothing to withdraw for this wallet.",
  EthTransferFailed: () => "BNB transfer failed.",
  StalePrice: () => "The Atlas BNB/USD price is stale (older than maxPriceAge).",
  InvalidPrice: () => "The Atlas BNB/USD price is invalid (<= 0).",
  InvalidConfig: () => "Invalid launcher configuration.",
  UnauthorizedDistribution: () => "Unauthorized distribution call.",
  // v2 launchers (VLEIMintLauncherV2 / VLEIMintVaultLauncherV2), ERC20 quote (USDT)
  NoAllowance: () =>
    "No allowance: approve the launcher on the quote token (USDT) first, up to maxContribution, then contribute() again.",
  NoQuoteBalance: () => "No quote-token balance (USDT) in this wallet. On testnet, mint test USDT first.",
  EntityCapReached: (a) => `Your legal entity already reached the cap: invested ${usd(a[0])} of ${usd(a[1])} per entity.`,
  UnexpectedNativeValue: (a) =>
    `This launcher raises in an ERC20 (USDT): send no BNB (got ${amt(a[0])} BNB). Approve USDT and contribute with value 0.`,
  NativeQuote: () => "contributeAmount is only for ERC20-quote launchers; this one raises BNB, use contribute() with a value.",
  QuoteTransferMismatch: (a) => `The quote token moved more than requested (requested ${amt(a[0])}, received ${amt(a[1])}).`,
  SafeERC20FailedOperation: (a) => `ERC20 transfer/approve failed on token ${a[0]}.`,
  ReentrancyGuardReentrantCall: () => "Reentrant call blocked.",
  InvalidInitialization: () => "Contract already initialized.",
  NotInitializing: () => "Not initializing.",
  // v2 factories
  PriceFeedNotUsed: (a) => `An ERC20-quote factory uses no price feed (got ${a[0]}).`,
  UnsupportedQuoteDecimals: (a) => `Quote token must have 18 decimals (has ${String(a[0])}).`,
  VaultFactoryNotPaired: (a) => `Vault factory ${a[0]} is not paired with this launcher factory.`,
  VaultQuoteMismatch: (a) => `Vault factory quote ${a[0]} differs from the launcher factory quote ${a[1]}.`,
  OwnableInvalidOwner: (a) => `Invalid owner ${a[0]}.`,
  // gated vault (VLEIDividendVaultV2)
  BelowMinStake: (a) => `Stake too small: ${amt(a[0])} tokens, the minimum is ${amt(a[1])}.`,
  InsufficientStake: (a) => `Cannot unstake ${amt(a[0])}: only ${amt(a[1])} staked.`,
  NotEvictable: (a) =>
    `${a[0]} is not evictable: only a staker whose vLEI was revoked, whose wallet moved to another LEI, or that expired more than 7 days ago can be evicted.`,
  QuoteTransferFailed: () => "Vault payout transfer (quote token) failed.",
  TokenDockNotConfigured: () => "The vault's token dock is not configured.",
  ZeroAmount: () => "Amount must be greater than zero.",
  StringsInsufficientHexLength: () => "Internal string formatting error.",
  // registry
  InvalidRole: () => "Attestation carries an invalid role.",
  InvalidNonce: () => "Attestation nonce does not match registry.nonces(wallet). Request a new challenge and verify again.",
  AttestationExpired: () => "Attestation has expired. Verify again.",
  TtlTooLong: () => "Attestation lifetime exceeds the registry's maxAttestationTtl.",
  InvalidSigner: (a) =>
    `Attestation was not signed by a registered verifier (recovered ${a[0]}). Check that the backend's chainId / registry address match this frontend.`,
  EntityIsRevoked: () => "This entity (LEI hash) has been revoked in the registry.",
  ZeroAddress: () => "Zero address not allowed.",
  AccessControlBadConfirmation: () => "renounceRole must be called by the account itself.",
  ECDSAInvalidSignature: () => "Invalid attestation signature.",
  ECDSAInvalidSignatureLength: (a) => `Invalid attestation signature length (${String(a[0])}).`,
  ECDSAInvalidSignatureS: () => "Invalid attestation signature (malleable s value).",
  InvalidShortString: () => "Invalid short string.",
  StringTooLong: () => "String too long.",
  AccessControlUnauthorizedAccount: (a) => `Connected wallet ${a[0]} lacks the required role (${String(a[1]).slice(0, 10)}…).`,
};

export function describeError(name: string, args: readonly unknown[] = []): string {
  const f = FRIENDLY[name];
  return f ? `${f(args)} [${name}]` : `${name}(${args.map(String).join(", ")})`;
}

/** Errors raised inside the Flap Portal (not in our ABIs), by selector. */
const PORTAL_ERRORS: Record<string, string> = {
  "0xa32ef056":
    "Flap Portal refused the launch (error 0xa32ef056, observed as a USD floor on the pool quote). The launcher catches this: status becomes Failed and refunds open.",
};

function portalError(raw: string | undefined): string | null {
  return raw ? PORTAL_ERRORS[raw.slice(0, 10).toLowerCase()] ?? null : null;
}

function findRevertData(err: unknown): Hex | undefined {
  let e: any = err;
  for (let i = 0; e && i < 10; i++) {
    const d = e.data ?? e.error?.data;
    if (typeof d === "string" && d.startsWith("0x") && d.length >= 10) return d as Hex;
    if (d && typeof d.data === "string" && d.data.startsWith("0x")) return d.data as Hex;
    e = e.cause;
  }
  return undefined;
}

/** Turn anything thrown by viem / the wallet / fetch into a readable sentence. */
export function explainError(err: unknown): string {
  if (err instanceof BaseError) {
    if (err.walk((e) => e instanceof UserRejectedRequestError)) return "Request rejected in the wallet.";
    const reverted = err.walk((e) => e instanceof ContractFunctionRevertedError) as ContractFunctionRevertedError | null;
    if (reverted) {
      if (reverted.data?.errorName) return describeError(reverted.data.errorName, reverted.data.args ?? []);
      if (reverted.raw) {
        try {
          const d = decodeErrorResult({ abi: allErrorsAbi, data: reverted.raw });
          return describeError(d.errorName, (d.args ?? []) as readonly unknown[]);
        } catch {
          /* fall through */
        }
      }
      if (reverted.reason) return `Reverted: ${reverted.reason}`;
    }
    const raw = findRevertData(err);
    const pe = portalError(raw ?? reverted?.raw);
    if (pe) return pe;
    if (raw) {
      try {
        const d = decodeErrorResult({ abi: allErrorsAbi, data: raw });
        return describeError(d.errorName, (d.args ?? []) as readonly unknown[]);
      } catch {
        /* fall through */
      }
    }
    return err.shortMessage || err.message;
  }
  const anyErr = err as any;
  if (anyErr?.code === 4001) return "Request rejected in the wallet.";
  if (err instanceof Error) return err.message;
  return String(err);
}
