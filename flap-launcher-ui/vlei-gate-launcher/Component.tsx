import { useEffect, useRef, useState, type CSSProperties, type ReactNode } from "react";

// ═══════════════════════════════════════════════════════════════════════════
// CONTRACT INTERFACE: the single place to reconcile with contracts/.
// The Workbench package allows exactly three files, so this block is the "ABI file".
// manifest.json mirrors READS and ACTIONS below (functionName / returns / account).
//
// VLEIMintLauncher views read by the host (manifest "reads"):
//   status() -> uint8 (0 Raising, 1 Launched, 2 Failed, 3 Cancelled)
//   raised() / targetRaise() / saleDeadline() -> uint256
//   creator() -> address; creatorActive() -> bool; token() -> address
//   bnbUsdPrice() -> uint256 USD x 1e18 (0 if invalid or stale, never reverts)
//   priceUpdatedAt() -> uint256; capUsdPerEntity() -> uint256 USD x 1e18
//   contributionOf(address) / claimableOf(address) / remainingCapUsd(address) -> uint256
//   vleiStatusOf(address) -> uint8 (0 none, 1 active, 2 expired, 3 wallet revoked, 4 entity revoked)
//   vleiRoleOf(address) -> uint8 (1 ECR, 2 OOR, 3 OOR officer); vleiExpiresAt(address) -> uint256
// Zero-argument actions (manifest "transactions.actions"):
//   contribute() payable; claim(); refund(); withdrawContribution(); cancelIfCreatorRevoked()
// ═══════════════════════════════════════════════════════════════════════════

/** Off-site link targets are not allowed in Launcher packages, so this URL is shown as text. */
const KYB_PORTAL_URL = "https://vlei-gate-kyb.fly.dev";
/** Display hint only, mirrors the launcher's maxPriceAge. TODO: confirm with contracts/. */
const MAX_PRICE_AGE_SECONDS = 3600n;
const STATUS = { raising: "0", launched: "1", failed: "2", cancelled: "3" } as const;
const VLEI = { none: "0", active: "1", expired: "2", walletRevoked: "3", entityRevoked: "4" } as const;
const ROLE_OOR_OFFICER = "3";

/**
 * Creation data passed to Portal.newLauncher(factory, data).
 * TODO(contracts): keep in sync with VLEILauncherFactory._newLauncher's abi.decode, currently
 *   abi.encode(VLEIMintConfig{ string name; string symbol; string meta; bytes32 salt;
 *                              uint256 targetRaise; uint256 saleDuration; uint256 capUsdPerEntity })
 * msg.value = Portal.SALT_LOCK_FEE() (from host.quote()); salt from host.findSalt() (token ends in 0x7777).
 */
const CREATE_PARAMETERS: readonly AbiParameter[] = [
  { name: "config", type: "tuple", components: [
    { name: "name", type: "string" },
    { name: "symbol", type: "string" },
    { name: "meta", type: "string" },
    { name: "salt", type: "bytes32" },
    { name: "targetRaise", type: "uint256" },
    { name: "saleDuration", type: "uint256" },
    { name: "capUsdPerEntity", type: "uint256" },
  ] },
];

/** Custom errors (name, 4-byte selector, message key). Selectors: keccak256(signature)[0:4]. */
const CONTRACT_ERRORS: readonly (readonly [string, string, string])[] = [
  ["CreatorNotAuthorized", "0x14baa470", "errCreatorNotAuthorized"],
  ["NotVerified", "0xa95362b5", "errNotVerified"],
  ["IssuerNotActive", "0x3d885c88", "errIssuerNotActive"],
  ["CapExceeded", "0x0cf95ce5", "errCapExceeded"],
  ["StalePrice", "0x19abf40e", "errStalePrice"],
  ["InvalidPrice", "0x00bfc921", "errInvalidPrice"],
  ["SaleClosed", "0x4c013bd7", "errSaleClosed"],
  ["ZeroContribution", "0xab82a248", "errZeroContribution"],
  ["NothingToClaim", "0x969bf728", "errNothingToClaim"],
  ["RefundUnavailable", "0x551a40dc", "errRefundUnavailable"],
  ["NothingToRefund", "0xf76aef65", "errNothingToRefund"],
  ["StillVerified", "0x658a1aca", "errStillVerified"],
  ["EntityMismatch", "0x2d8d9b2b", "errEntityMismatch"],
  ["SaleIsCancelled", "0x3d46ca1e", "errSaleIsCancelled"],
  ["LaunchInProgress", "0x2218e1f3", "errLaunchInProgress"],
  ["EntityIsRevoked", "0x677d29f3", "errEntityIsRevoked"],
  ["AlreadyLaunched", "0xcfa6d878", "errAlreadyLaunched"],
  ["AlreadyCancelled", "0x54e37625", "errAlreadyCancelled"],
  ["IssuerStillActive", "0xac770294", "errIssuerStillActive"],
  ["NothingToWithdraw", "0xd0d04f60", "errNothingToWithdraw"],
  ["EthTransferFailed", "0x6d963f88", "errEthTransferFailed"],
  ["DistributionNotInitialized", "0xd35eb600", "errDistributionNotInitialized"],
  ["NotFactory", "0xb550282e", "errNotFactory"],
  ["InsufficientLaunchGas", "0xd3abcf23", "errInsufficientLaunchGas"],
  ["TargetBelowMinimum", "0xfd9a1642", "errTargetBelowMinimum"],
  // Flap Portal: target below its liquidity floor (~$1,500), (uint256,uint256). Matched by selector only.
  ["PortalLiquidityFloor", "0xa32ef056", "errPortalLiquidityFloor"],
];
/** Creation rule enforced by the factory (TargetBelowMinimum). saleDuration > 30 days reverts InvalidConfig. */
const MIN_TARGET_USD = "1,600";
/**
 * The contribution that fills the target runs the launch and needs MIN_LAUNCH_GAS (7,000,000) left,
 * i.e. a gas limit of about 7.1M or more (else InsufficientLaunchGas). host.submit() takes no gas
 * parameter, so the UI can only tell the user to keep the wallet's limit at or above this value.
 */
const LAUNCH_GAS_HINT = "8,000,000";
// ═══════════════════════════════════════════════════════════════════════════

type Messages = Record<string, string>;
type Identity = Readonly<{ chainId: number; factoryAddress: string }>;
type Wallet = Readonly<{
  account: string | null;
  chainId: number | null;
  pendingHash?: string | null;
  connect(): void;
  switchChain(): Promise<void>;
}>;
type Action = "contribute" | "claim" | "refund" | "withdrawContribution" | "cancelIfCreatorRevoked";
type Submission = { status: "success" | "pending" | "reverted" | "unverified"; hash: string; launcherAddress?: string };
type AbiParameter = { name: string; type: string; components?: readonly AbiParameter[] };
type Host = Readonly<{
  wallet?: Wallet;
  quote?(): Promise<string | null>;
  encode?(parameters: readonly AbiParameter[], values: readonly unknown[]): string;
  findSalt?(): Promise<string>;
  submit?(input: { kind: "create"; configuration: string; valueWei: string }
    | { kind: "action"; action: Action; valueWei?: string }): Promise<Submission>;
  checkReceipt?(hash: string): Promise<Submission>;
  refresh?(): void;
  redirect?(path: string): boolean;
  openLauncher?(address: string): void;
}>;
type Snapshot = Readonly<{
  status?: string | null;
  raised?: string | null;
  targetRaise?: string | null;
  saleDeadline?: string | null;
  creator?: string | null;
  creatorActive?: boolean | null;
  bnbUsdPrice?: string | null;
  priceUpdatedAt?: string | null;
  capUsdPerEntity?: string | null;
  token?: string | null;
  contribution?: string | null;
  claimable?: string | null;
  remainingCapUsd?: string | null;
  vleiStatus?: string | null;
  vleiRole?: string | null;
  vleiExpiresAt?: string | null;
}>;
type ConfigProps = {
  context: Readonly<{ identity: Identity; locale: string; previewOnly?: boolean }>;
  messages: Messages;
  host?: Host;
};
type DetailProps = {
  context: Readonly<{
    identity: Identity;
    locale: string;
    previewOnly?: boolean;
    launcherAddress: string | null;
    snapshot: Snapshot | null;
  }>;
  messages: Messages;
  host?: Host;
};

// ─── Styling ────────────────────────────────────────────────────────────────
const ink = "#13223a";
const navy = "#0f2a52";
const paper = "#f4f7fb";
const slate = "#51607a";
const rule = "#c9d3e3";
const accent = "#f0b90b";
const good = "#1f7a4d";
const bad = "#a3261d";

const shell: CSSProperties = {
  color: ink, background: paper, border: "1px solid #9fb0cb", borderRadius: 16, overflow: "hidden",
  fontFamily: '"Inter", "PingFang SC", "Apple SD Gothic Neo", system-ui, sans-serif',
  lineHeight: 1.5, colorScheme: "light", accentColor: navy,
};
const inset = "clamp(16px, 5vw, 32px)";
const body: CSSProperties = { padding: inset, display: "grid", gap: 22 };
const columns: CSSProperties = {
  display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(min(100%, 180px), 1fr))", gap: 14,
};
const input: CSSProperties = {
  appearance: "none", boxSizing: "border-box", minWidth: 0, width: "100%", minHeight: 44,
  border: "1px solid #9fb0cb", borderRadius: 7, padding: "9px 11px", color: ink,
  background: "#ffffff", font: "inherit", fontSize: 16, outlineOffset: 3,
};
const mono: CSSProperties = {
  fontFamily: '"IBM Plex Mono", ui-monospace, monospace', fontVariantNumeric: "tabular-nums",
  overflowWrap: "anywhere", margin: "3px 0 0",
};
const muted: CSSProperties = { margin: 0, color: slate, fontSize: 13 };
const notice: CSSProperties = { margin: 0, color: bad, fontSize: 13 };
const card: CSSProperties = { border: `1px solid ${rule}`, borderRadius: 12, padding: "clamp(14px, 3vw, 20px)", background: "#ffffff", display: "grid", gap: 12 };

function buttonStyle(disabled = false, secondary = false): CSSProperties {
  return {
    minHeight: 44, borderRadius: 8, padding: "8px 16px", border: secondary ? `1px solid ${rule}` : 0,
    background: secondary ? "transparent" : navy, color: secondary ? ink : "#ffffff",
    font: "inherit", fontSize: 14, fontWeight: 700,
    opacity: disabled ? 0.5 : 1, cursor: disabled ? "default" : "pointer",
  };
}

// ─── Helpers ────────────────────────────────────────────────────────────────
const addressPattern = /^0x(?!0{40}$)[a-f0-9]{40}$/i;
const hashPattern = /^0x[a-f0-9]{64}$/i;
const unsigned = /^(0|[1-9][0-9]{0,77})$/;
const WAD = 10n ** 18n;

function asUnits(value: string | null | undefined) {
  return typeof value === "string" && unsigned.test(value) ? BigInt(value) : null;
}

function isHash(value: unknown): value is string {
  return typeof value === "string" && hashPattern.test(value);
}

function decimalAmount(value: bigint, digits = 18) {
  const scale = 10n ** BigInt(digits);
  const fraction = (value % scale).toString().padStart(digits, "0").replace(/0+$/, "");
  return `${value / scale}${fraction ? "." + fraction : ""}`;
}

const decimalPatterns: Record<number, RegExp> = {
  6: /^(0|[1-9][0-9]{0,5})(?:\.([0-9]{1,18}))?$/,
  7: /^(0|[1-9][0-9]{0,6})(?:\.([0-9]{1,18}))?$/,
  12: /^(0|[1-9][0-9]{0,11})(?:\.([0-9]{1,18}))?$/,
};

function parseDecimal(text: string, maxWhole: 6 | 7 | 12) {
  const match = decimalPatterns[maxWhole].exec(text.trim());
  return match ? BigInt(match[1]) * WAD + BigInt((match[2] ?? "").padEnd(18, "0")) : null;
}

function bnb(value: bigint | null, fallback: string) {
  return value === null ? fallback : `${decimalAmount(value)} tBNB`;
}

/** USD with 18 decimals, rounded down to cents. */
function usd(value: bigint | null, fallback: string) {
  if (value === null) return fallback;
  const cents = value / 10n ** 16n;
  const whole = (cents / 100n).toString().replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  return `$${whole}.${(cents % 100n).toString().padStart(2, "0")}`;
}

function shortAddress(value: string) {
  return `${value.slice(0, 8)}…${value.slice(-6)}`;
}

function readableTime(seconds: bigint | null, fallback: string, locale: string) {
  return seconds !== null && seconds > 0n && seconds <= 253402300799n
    ? Intl.DateTimeFormat(locale, {
        timeZone: "UTC", year: "numeric", month: "short", day: "numeric",
        hour: "2-digit", minute: "2-digit", hourCycle: "h23",
      }).format(Number(seconds) * 1000) + " UTC"
    : fallback;
}

function duration(seconds: bigint, m: Messages) {
  const s = seconds < 0n ? 0n : seconds;
  const days = s / 86400n, hours = (s % 86400n) / 3600n, minutes = (s % 3600n) / 60n;
  return days > 0n ? `${days}${m.unitDay} ${hours}${m.unitHour}` : `${hours}${m.unitHour} ${minutes}${m.unitMinute}`;
}

function useNow() {
  const [now, setNow] = useState(() => BigInt(Math.floor(Date.now() / 1000)));
  useEffect(() => {
    const timer = setInterval(() => setNow(BigInt(Math.floor(Date.now() / 1000))), 15_000);
    return () => clearInterval(timer);
  }, []);
  return now;
}

/** Maps host wallet codes, then any custom error name or selector the host may surface. */
function readableError(cause: unknown, m: Messages, fallback: string) {
  if (!(cause instanceof Error)) return fallback;
  const hostCodes: Record<string, string> = {
    walletUnavailable: m.walletUnavailable, connectWallet: m.connectWallet, wrongChain: m.switchChain,
    walletRejected: m.walletRejected, walletBusy: m.walletBusy, simulationFailed: m.simulationFailed,
    creationFeeChanged: m.feeChanged, factoryUnavailable: m.factoryUnavailable,
    invalidTransaction: m.submitError, saltUnavailable: m.saltUnavailable, receiptUnavailable: m.receiptError,
  };
  if (Object.hasOwn(hostCodes, cause.message)) return hostCodes[cause.message];
  const text = cause.message.toLowerCase();
  const known = CONTRACT_ERRORS.find(([name, selector]) => text.includes(selector) || text.includes(name.toLowerCase()));
  return known ? m[known[2]] : fallback;
}

function visibleReceipt(receipt: Submission | null, pendingHash: string | null | undefined): Submission | null {
  if (isHash(pendingHash) && receipt?.hash !== pendingHash) return { status: "pending", hash: pendingHash };
  return receipt;
}

function recoveryNeeded(receipt: Submission | null) {
  return receipt?.status === "pending" || receipt?.status === "unverified";
}

function ReceiptStatus({ receipt, m }: { receipt: Submission | null; m: Messages }) {
  if (!receipt) return null;
  const labels = { success: m.success, pending: m.pending, reverted: m.reverted, unverified: m.unverified };
  return (
    <div role="status" style={{ ...muted, display: "grid", gap: 4 }}>
      <span>{labels[receipt.status]}</span>
      {isHash(receipt.hash) && <span style={mono}>{receipt.hash}</span>}
    </div>
  );
}

function Header({ title, intro, m }: { title: string; intro: string; m: Messages }) {
  return (
    <header style={{ color: "#ffffff", padding: inset, background: navy, borderBlockStart: `5px solid ${accent}`, display: "grid", gap: 8 }}>
      <div style={{ display: "flex", justifyContent: "space-between", gap: 12, flexWrap: "wrap", alignItems: "flex-start" }}>
        <h2 style={{ margin: 0, fontSize: "clamp(24px, 5vw, 38px)", lineHeight: 1.12, letterSpacing: "-0.03em" }}>{title}</h2>
        <span style={{ padding: "3px 10px", border: "1px solid #7f9bc7", borderRadius: 20, fontSize: 12, whiteSpace: "nowrap" }}>{m.network}</span>
      </div>
      <p style={{ margin: 0, fontSize: 14, color: "#c8d6ee" }}>{intro}</p>
      <p style={{ margin: 0, fontSize: 13, color: accent, fontWeight: 700 }}>{m.tagline}</p>
    </header>
  );
}

function Field({ label, hint, children }: { label: string; hint?: string; children: ReactNode }) {
  return (
    <label style={{ display: "grid", gap: 5, minWidth: 0, alignContent: "start" }}>
      <span style={{ fontWeight: 700, fontSize: 14 }}>{label}</span>
      {children}
      {hint && <span style={muted}>{hint}</span>}
    </label>
  );
}

function Datum({ label, children }: { label: string; children: ReactNode }) {
  return <div style={{ minWidth: 0 }}><dt style={muted}>{label}</dt><dd style={{ ...mono, marginInlineStart: 0 }}>{children}</dd></div>;
}

function Pill({ tone, children }: { tone: "good" | "bad" | "neutral"; children: ReactNode }) {
  const colors = { good: [good, "#e2f4ea"], bad: [bad, "#fbe7e5"], neutral: [slate, "#e8edf5"] }[tone];
  return (
    <span style={{ display: "inline-block", borderRadius: 16, padding: "3px 11px", fontSize: 13, fontWeight: 700,
      color: colors[0], background: colors[1], border: `1px solid ${colors[0]}` }}>{children}</span>
  );
}

function KybPortalHint({ m }: { m: Messages }) {
  return (
    <p style={muted}>
      {m.kybPortalHint} <span style={{ ...mono, display: "inline", userSelect: "all", color: ink }}>{KYB_PORTAL_URL}</span>
    </p>
  );
}

// ─── Creation surface ───────────────────────────────────────────────────────
const initialForm = { name: "", symbol: "", meta: "", targetRaise: "", saleHours: "72", capUsd: "" };
type Form = typeof initialForm;
const MIN_SALE_HOURS = 1;
const MAX_SALE_HOURS = 24 * 30;

function reviewConfiguration(form: Form) {
  const name = form.name.trim(), symbol = form.symbol.trim(), meta = form.meta.trim();
  const targetRaise = parseDecimal(form.targetRaise, 6);
  const hours = /^[1-9][0-9]{0,3}$/.test(form.saleHours) ? Number(form.saleHours) : null;
  const capUsdPerEntity = parseDecimal(form.capUsd, 12);
  if (!name || name.length > 64 || !symbol || symbol.length > 16 || meta.length > 512
    || targetRaise === null || targetRaise <= 0n || hours === null || hours < MIN_SALE_HOURS || hours > MAX_SALE_HOURS
    || capUsdPerEntity === null || capUsdPerEntity <= 0n) return null;
  return { name, symbol, meta, targetRaise, saleDuration: BigInt(hours * 3600), capUsdPerEntity };
}

type Draft = NonNullable<ReturnType<typeof reviewConfiguration>>;

export function LauncherConfig({ context, messages: m, host }: ConfigProps) {
  const [form, setForm] = useState<Form>(initialForm);
  const [review, setReview] = useState<{ values: Draft; fee: string | null } | null>(null);
  const [prepared, setPrepared] = useState<{ configuration: string; account: string; valueWei: string } | null>(null);
  const [result, setResult] = useState<{ account: string; receipt: Submission } | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const lock = useRef(false);
  const draft = reviewConfiguration(form);
  const account = host?.wallet?.account?.toLowerCase() ?? null;
  const wrongChain = host?.wallet?.chainId !== context.identity.chainId;
  const canTransact = context.identity.chainId === 97 && !!host?.wallet && !!host?.quote
    && !!host?.findSalt && !!host?.encode && !!host?.submit;
  const receipt = visibleReceipt(result?.account === account ? result.receipt : null, host?.wallet?.pendingHash);
  const waiting = recoveryNeeded(receipt);
  const finished = receipt?.status === "success";
  const created = finished && typeof receipt?.launcherAddress === "string" && addressPattern.test(receipt.launcherAddress)
    ? receipt.launcherAddress : null;
  const sameWallet = !!account && prepared?.account === account;

  const update = (key: keyof Form, value: string) => {
    setForm(current => ({ ...current, [key]: value }));
    setReview(null);
    setPrepared(null);
    setError(null);
  };

  async function guarded(task: () => Promise<void>, fallback: string) {
    if (lock.current) return;
    lock.current = true;
    setBusy(true);
    setError(null);
    try { await task(); }
    catch (cause) {
      const text = readableError(cause, m, fallback);
      // On creation, a failed simulation almost always means the factory's vLEI gate rejected the creator.
      setError(cause instanceof Error && cause.message === "simulationFailed" ? m.errCreationRejectedLikely : text);
    } finally {
      lock.current = false;
      setBusy(false);
    }
  }

  const showReview = () => guarded(async () => {
    const values = reviewConfiguration(form);
    if (!values) return;
    const fee = canTransact ? await host?.quote?.() : null;
    const valid = fee != null && unsigned.test(fee);
    if (canTransact && !valid) setError(m.feeUnavailable);
    setReview({ values, fee: valid ? fee : null });
  }, m.feeUnavailable);

  const prepareCreation = () => guarded(async () => {
    if (!canTransact || !review || !draft || finished || waiting) return;
    if (!account) { host?.wallet?.connect(); return; }
    if (wrongChain) { await host?.wallet?.switchChain(); return; }
    setPrepared(null);
    const fee = await host?.quote?.();
    if (fee == null || !unsigned.test(fee)) { setError(m.feeUnavailable); return; }
    if (fee !== review.fee) { setReview({ ...review, fee }); setError(m.feeChanged); return; }
    const salt = await host?.findSalt?.();
    if (!isHash(salt)) { setError(m.saltUnavailable); return; }
    const v = review.values;
    // TODO(contracts): field order must match VLEIMintConfig exactly.
    const configuration = host?.encode?.(CREATE_PARAMETERS, [{
      name: v.name, symbol: v.symbol, meta: v.meta, salt,
      targetRaise: v.targetRaise, saleDuration: v.saleDuration, capUsdPerEntity: v.capUsdPerEntity,
    }]);
    if (!configuration) { setError(m.prepareError); return; }
    setPrepared({ configuration, account, valueWei: fee });
  }, m.prepareError);

  const confirmCreation = () => guarded(async () => {
    if (!canTransact || !prepared || !account || !sameWallet || wrongChain || finished || waiting) return;
    if (!reviewConfiguration(form)) { setPrepared(null); setError(m.draftIncomplete); return; }
    setResult(null);
    try {
      const submitted = await host?.submit?.({ kind: "create", configuration: prepared.configuration, valueWei: prepared.valueWei });
      if (submitted) setResult({ account, receipt: submitted });
    } finally {
      setPrepared(null);
    }
  }, m.submitError);

  const checkCreation = () => guarded(async () => {
    if (!account || !receipt || !isHash(receipt.hash)) return;
    const checked = await host?.checkReceipt?.(receipt.hash);
    if (checked) setResult({ account, receipt: checked });
  }, m.receiptError);

  const { name, symbol, meta, targetRaise, saleHours, capUsd } = form;
  const targetInvalid = targetRaise !== "" && (parseDecimal(targetRaise, 6) ?? 0n) <= 0n;
  const hoursValue = Number(saleHours);
  const hoursInvalid = saleHours !== "" && (!/^[1-9][0-9]{0,3}$/.test(saleHours) || hoursValue < MIN_SALE_HOURS || hoursValue > MAX_SALE_HOURS);
  const capInvalid = capUsd !== "" && (parseDecimal(capUsd, 12) ?? 0n) <= 0n;
  const factory = context.identity.factoryAddress;

  return (
    <section style={shell} aria-label={m.createTitle}>
      <Header title={m.createTitle} intro={m.createIntro} m={m} />
      <div style={body}>
        <div style={{ ...card, borderColor: accent, background: "#fffaf0" }} aria-label={m.eligibilityTitle}>
          <h3 style={{ margin: 0, fontSize: 16 }}>{m.eligibilityTitle}</h3>
          <p style={{ margin: 0, fontSize: 14 }}>{m.eligibilityRule}</p>
          <dl style={{ ...columns, margin: 0 }}>
            <Datum label={m.walletAccount}>{account ?? m.notConnected}</Datum>
            <Datum label={m.canLaunchLabel}>{m.canLaunchChecked}</Datum>
          </dl>
          <p style={muted}>{m.eligibilityHostLimit}</p>
          <KybPortalHint m={m} />
          {!account && host?.wallet && (
            <button type="button" style={{ ...buttonStyle(), justifySelf: "start" }} onClick={() => host?.wallet?.connect()}>{m.connectWallet}</button>
          )}
        </div>

        <div style={{ display: "grid", gap: 22, gridTemplateColumns: "repeat(auto-fit, minmax(min(100%, 268px), 1fr))", alignItems: "start" }}>
          <fieldset disabled={busy || waiting || finished} style={{ display: "grid", gap: 14, minWidth: 0, border: 0, padding: 0, margin: 0 }}>
            <h3 style={{ margin: 0, fontSize: 16 }}>{m.tokenSection}</h3>
            <div style={columns}>
              <Field label={m.name}><input name="name" value={name} maxLength={64} autoComplete="off" style={input}
                onChange={event => update("name", event.target.value)} /></Field>
              <Field label={m.symbol}><input name="symbol" value={symbol} maxLength={16} autoComplete="off" style={input}
                onChange={event => update("symbol", event.target.value)} /></Field>
            </div>
            <Field label={m.meta} hint={m.metaHint}><input name="meta" value={meta} maxLength={512} autoComplete="off" style={input}
              onChange={event => update("meta", event.target.value)} /></Field>
            <h3 style={{ margin: 0, paddingBlockStart: 12, borderBlockStart: `1px solid ${rule}`, fontSize: 16 }}>{m.saleSection}</h3>
            <div style={columns}>
              <Field label={m.targetRaiseInput} hint={`${m.targetRaiseHint} ${m.targetMinimumHint} $${MIN_TARGET_USD}.`}><input name="targetRaise" value={targetRaise} inputMode="decimal"
                maxLength={26} aria-invalid={targetInvalid} style={input} onChange={event => update("targetRaise", event.target.value)} /></Field>
              <Field label={m.saleDurationInput} hint={m.saleDurationHint}><input name="saleHours" value={saleHours} inputMode="numeric"
                maxLength={4} aria-invalid={hoursInvalid} style={input} onChange={event => update("saleHours", event.target.value)} /></Field>
            </div>
            <Field label={m.capUsdInput} hint={m.capUsdHint}><input name="capUsdPerEntity" value={capUsd} inputMode="decimal"
              maxLength={32} aria-invalid={capInvalid} style={input} onChange={event => update("capUsd", event.target.value)} /></Field>
          </fieldset>

          <aside style={{ ...card, background: "#e9eef7" }}>
            <h3 style={{ margin: 0, fontSize: 17 }}>{review ? m.reviewCreation : m.summary}</h3>
            <dl style={{ margin: 0, display: "grid", gap: 12 }}>
              <Datum label={m.token}>{(draft?.name ?? (name.trim() || m.unknown)) + (symbol.trim() ? ` (${symbol.trim()})` : "")}</Datum>
              <Datum label={m.targetRaise}>{bnb(draft?.targetRaise ?? null, m.unknown)}</Datum>
              <Datum label={m.saleDuration}>{draft ? duration(draft.saleDuration, m) : m.unknown}</Datum>
              <Datum label={m.capUsdPerEntity}>{usd(draft?.capUsdPerEntity ?? null, m.unknown)}</Datum>
              <Datum label={m.access}>{m.accessRule}</Datum>
              <Datum label={m.factory}><span title={factory}>{shortAddress(factory)}</span></Datum>
              {review && canTransact && <Datum label={m.creationFee}>{bnb(asUnits(review.fee), m.unknown)}</Datum>}
              {sameWallet && <Datum label={m.walletAccount}>{account}</Datum>}
            </dl>
            <p role="status" style={{ margin: 0, paddingBlockStart: 10, borderBlockStart: `1px solid ${rule}`, fontSize: 13, fontWeight: 700 }}>
              {review ? canTransact ? (sameWallet ? m.confirmReady : m.prepareHelp) : m.reviewOnly
                : draft ? m.draftReady : m.draftIncomplete}
            </p>
            {error && <p role="alert" style={notice}>{error}</p>}
            {error === m.errCreationRejectedLikely && <KybPortalHint m={m} />}
            <ReceiptStatus receipt={receipt} m={m} />
            {created && (
              <>
                <dl style={{ margin: 0 }}><Datum label={m.launcher}>{created}</Datum></dl>
                {host?.openLauncher && <button type="button" style={buttonStyle()} onClick={() => host?.openLauncher?.(created)}>{m.openLauncher}</button>}
              </>
            )}
            {waiting && host?.checkReceipt && (
              <button type="button" disabled={busy} style={buttonStyle(busy)} onClick={() => void checkCreation()}>{m.checkReceipt}</button>
            )}
            {!waiting && !finished && (
              <div style={{ display: "grid", gap: 8 }}>
                {review && canTransact && (
                  <button type="button" disabled={busy || !draft} style={buttonStyle(busy || !draft)}
                    onClick={sameWallet && !wrongChain ? () => void confirmCreation() : () => void prepareCreation()}>
                    {busy ? m.working : !account ? m.connectWallet : wrongChain ? m.switchChain
                      : sameWallet ? m.confirmCreation : m.prepareCreation}
                  </button>
                )}
                <button type="button" disabled={busy || (!draft && !review)} style={buttonStyle(busy || (!draft && !review), !!review)}
                  onClick={review ? () => { setReview(null); setPrepared(null); setError(null); } : () => void showReview()}>
                  {review ? m.editConfiguration : busy ? m.working : m.reviewCreation}
                </button>
              </div>
            )}
          </aside>
        </div>
      </div>
    </section>
  );
}

// ─── Detail surface ─────────────────────────────────────────────────────────
type Gate = { enabled: boolean; reason: string | null };

export function Launcher({ context, messages: m, host }: DetailProps) {
  const [amount, setAmount] = useState("");
  const [review, setReview] = useState<{ action: Action; account: string; valueWei?: string } | null>(null);
  const [result, setResult] = useState<{ account: string; action?: Action; receipt: Submission } | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const lock = useRef(false);
  const now = useNow();
  const { launcherAddress, snapshot: s, identity, locale } = context;

  const status = s?.status ?? null;
  const raised = asUnits(s?.raised);
  const target = asUnits(s?.targetRaise);
  const deadline = asUnits(s?.saleDeadline);
  const price = asUnits(s?.bnbUsdPrice);
  const priceAt = asUnits(s?.priceUpdatedAt);
  const capPerEntity = asUnits(s?.capUsdPerEntity);
  const contribution = asUnits(s?.contribution);
  const claimable = asUnits(s?.claimable);
  const remainingCap = asUnits(s?.remainingCapUsd);
  const expiresAt = asUnits(s?.vleiExpiresAt);
  const vleiStatus = s?.vleiStatus ?? null;
  const role = s?.vleiRole ?? null;
  const token = s?.token && addressPattern.test(s.token) ? s.token : null;

  const progressBps = raised !== null && target !== null && target > 0n ? raised * 10_000n / target : null;
  const progress = progressBps === null ? null : Number(progressBps > 10_000n ? 10_000n : progressBps) / 100;
  const remainingTarget = raised !== null && target !== null && target > raised ? target - raised : 0n;
  const raising = status === STATUS.raising;
  const open = raising && deadline !== null && now < deadline;
  const pastDeadline = raising && deadline !== null && now >= deadline;
  const failed = status === STATUS.failed || pastDeadline;
  const cancelled = status === STATUS.cancelled;
  const launched = status === STATUS.launched;
  const verified = vleiStatus === VLEI.active;
  const priceStale = priceAt !== null && priceAt > 0n && now > priceAt + MAX_PRICE_AGE_SECONDS;

  const statusLabel = launched ? m.statusLaunched : cancelled ? m.statusCancelled : failed ? m.statusFailed
    : open ? m.statusRaising : m.unknown;

  const inputWei = parseDecimal(amount, 7);
  // contribute() accepts min(value, target - raised) and refunds the excess in the same transaction.
  const acceptedWei = inputWei === null ? null : inputWei > remainingTarget ? remainingTarget : inputWei;
  const excessWei = inputWei !== null && acceptedWei !== null ? inputWei - acceptedWei : 0n;
  const fillsTarget = acceptedWei !== null && acceptedWei > 0n && acceptedWei === remainingTarget;
  const inputUsd = acceptedWei !== null && price !== null && price > 0n ? acceptedWei * price / WAD : null;

  const account = host?.wallet?.account?.toLowerCase() ?? null;
  const wrongChain = host?.wallet?.chainId !== identity.chainId;
  const canTransact = identity.chainId === 97 && !!host?.wallet && !!host?.submit;
  const currentResult = result?.account === account ? result : null;
  const receipt = visibleReceipt(currentResult?.receipt ?? null, host?.wallet?.pendingHash);
  const waiting = recoveryNeeded(receipt);

  const vleiReason = vleiStatus === VLEI.expired ? m.errExpired
    : vleiStatus === VLEI.walletRevoked ? m.errWalletRevoked
      : vleiStatus === VLEI.entityRevoked ? m.errEntityIsRevoked : m.errNotVerified;

  // Predict the contract's custom errors from on-chain reads, since the host exposes no revert data.
  function contributeGate(): Gate {
    if (!open) return { enabled: false, reason: cancelled ? m.errSaleIsCancelled : m.errSaleClosed };
    if (!verified) return { enabled: false, reason: vleiReason };
    if (s?.creatorActive === false) return { enabled: false, reason: m.errIssuerNotActive };
    if (remainingTarget === 0n) return { enabled: false, reason: m.errSaleClosed };
    if (price === null || price === 0n) return { enabled: false, reason: priceStale ? m.errStalePrice : m.errInvalidPrice };
    if (inputWei === null || inputWei === 0n) return { enabled: false, reason: amount ? m.errZeroContribution : null };
    if (inputUsd !== null && remainingCap !== null && inputUsd > remainingCap) return { enabled: false, reason: m.errCapExceeded };
    return { enabled: true, reason: null };
  }
  const gates: Record<Action, Gate> = {
    contribute: contributeGate(),
    claim: !launched ? { enabled: false, reason: null }
      : claimable === null || claimable === 0n ? { enabled: false, reason: m.errNothingToClaim }
        : !verified ? { enabled: false, reason: vleiReason } : { enabled: true, reason: null },
    refund: !(failed || cancelled) || contribution === null || contribution === 0n
      ? { enabled: false, reason: null } : { enabled: true, reason: null },
    // Needs a real revocation or LEI change (status 3/4, or 0 if cleared). Mere expiry reverts StillVerified.
    withdrawContribution: !raising || contribution === null || contribution === 0n || failed
      || verified || vleiStatus === null ? { enabled: false, reason: null }
      : vleiStatus === VLEI.expired ? { enabled: false, reason: m.errWithdrawExpired }
        : { enabled: true, reason: null },
    // creatorActive false means paused. Whether cancel is allowed yet (revocation, LEI/role change, or
    // expiry + 7 days) is not readable, so the button is offered and a failed simulation is explained.
    cancelIfCreatorRevoked: raising && s?.creatorActive === false
      ? { enabled: true, reason: null } : { enabled: false, reason: null },
  };
  const labels: Record<Action, string> = {
    contribute: m.contribute, claim: m.claim, refund: m.refund,
    withdrawContribution: m.withdrawContribution, cancelIfCreatorRevoked: m.cancelIfCreatorRevoked,
  };
  const helps: Partial<Record<Action, string>> = {
    refund: m.refundHelp, withdrawContribution: m.withdrawHelp, cancelIfCreatorRevoked: m.cancelHelp, claim: m.claimHelp,
  };

  function ready(action: Action) {
    return gates[action].enabled
      && !(receipt?.status === "success" && currentResult?.action === action && action !== "contribute");
  }

  function startAction(action: Action) {
    if (!canTransact || !account || wrongChain || !ready(action) || waiting || lock.current) return;
    setError(null);
    setReview({ action, account, ...(action === "contribute" && inputWei !== null ? { valueWei: inputWei.toString() } : {}) });
  }

  async function guarded(task: () => Promise<void>, fallback: string, failedAction?: Action) {
    if (lock.current) return;
    lock.current = true;
    setBusy(true);
    setError(null);
    try { await task(); }
    catch (cause) {
      const simulationHints: Partial<Record<Action, string>> = {
        cancelIfCreatorRevoked: m.errCancelNotYetAllowed,
        withdrawContribution: m.errStillVerified,
        contribute: fillsTarget ? m.errInsufficientLaunchGas : m.simulationFailed,
      };
      const predicted = failedAction ? gates[failedAction].reason ?? simulationHints[failedAction] ?? null : null;
      setError(cause instanceof Error && cause.message === "simulationFailed" && predicted
        ? predicted : readableError(cause, m, fallback));
    } finally {
      lock.current = false;
      setBusy(false);
    }
  }

  function record(submitted: Submission, action?: Action) {
    if (!account) return;
    setResult({ account, action, receipt: submitted });
    if (submitted.status === "success") {
      if (action === "contribute") setAmount("");
      host?.refresh?.();
    }
  }

  const confirmAction = () => {
    const current = review;
    return guarded(async () => {
      try {
        if (!current || !canTransact || !ready(current.action) || waiting || wrongChain || account !== current.account
          || (current.action === "contribute" && current.valueWei !== inputWei?.toString())) return;
        setResult(null);
        const submitted = await host?.submit?.({ kind: "action", action: current.action,
          ...(current.valueWei === undefined ? {} : { valueWei: current.valueWei }) });
        if (submitted) record(submitted, current.action);
      } finally {
        setReview(null);
      }
    }, m.submitError, current?.action);
  };

  const checkAction = () => guarded(async () => {
    if (!receipt || !isHash(receipt.hash)) return;
    const checked = await host?.checkReceipt?.(receipt.hash);
    if (checked) record(checked, currentResult?.action);
  }, m.receiptError);

  const switchChain = () => guarded(async () => { await host?.wallet?.switchChain(); }, m.walletUnavailable);

  const reviewStale = !!review && (!ready(review.action) || review.account !== account || wrongChain);
  const roleLabel = role === "1" ? m.roleEcr : role === "2" ? m.roleOor : role === ROLE_OOR_OFFICER ? m.roleOfficer : m.roleNone;
  const badge = !account ? null
    : verified ? <Pill tone="good">{m.badgeVerified}</Pill>
      : vleiStatus === VLEI.expired ? <Pill tone="bad">{m.badgeExpired}</Pill>
        : vleiStatus === VLEI.walletRevoked || vleiStatus === VLEI.entityRevoked ? <Pill tone="bad">{m.badgeRevoked}</Pill>
          : vleiStatus === VLEI.none ? <Pill tone="neutral">{m.badgeNone}</Pill> : <Pill tone="neutral">{m.unknown}</Pill>;
  const visibleActions = (Object.keys(gates) as Action[]).filter(action =>
    action === "contribute" ? open : gates[action].enabled || !!gates[action].reason);

  return (
    <section style={shell} aria-label={m.detailTitle}>
      <Header title={m.detailTitle} intro={m.detailIntro} m={m} />
      <div style={body}>
        {!launcherAddress ? <p role="status" style={muted}>{m.noInstance}</p> : (
          <>
            <div style={{ ...card, background: "#e9eef7" }}>
              <div style={{ display: "flex", gap: 8, justifyContent: "space-between", alignItems: "start", flexWrap: "wrap" }}>
                <div>
                  <p style={muted}>{m.raised}</p>
                  <p style={{ ...mono, fontSize: "clamp(24px, 6vw, 40px)", lineHeight: 1.15, fontWeight: 750 }}>{bnb(raised, m.unknown)}</p>
                </div>
                <Pill tone={launched ? "good" : failed || cancelled ? "bad" : "neutral"}>{statusLabel}</Pill>
              </div>
              {progress !== null && (
                <div style={{ display: "grid", gap: 6 }}>
                  <div role="progressbar" aria-label={m.progress} aria-valuenow={progress} aria-valuemin={0} aria-valuemax={100}
                    style={{ height: 10, background: "#cdd8ea", borderRadius: 8, overflow: "hidden" }}>
                    <div style={{ background: navy, width: progress + "%", height: "100%" }} />
                  </div>
                  <p style={muted}>{progress}% · {m.targetRaise} {bnb(target, m.unknown)}</p>
                </div>
              )}
              <dl style={{ ...columns, margin: 0 }}>
                <Datum label={m.deadline}>{readableTime(deadline, m.unknown, locale)}</Datum>
                {open && deadline !== null && <Datum label={m.timeLeft}>{duration(deadline - now, m)}</Datum>}
                <Datum label={m.capUsdPerEntity}>{usd(capPerEntity, m.unknown)}</Datum>
                {token && <Datum label={m.issuedToken}>{token}</Datum>}
              </dl>
              {!s && <p role="status" style={muted}>{m.noData}</p>}
              {s?.creatorActive === false && <p role="alert" style={notice}>{m.creatorRevokedNotice}</p>}
            </div>

            <div style={card}>
              <h3 style={{ margin: 0, fontSize: 16 }}>{m.priceTitle}</h3>
              <dl style={{ ...columns, margin: 0 }}>
                <Datum label={m.atlasPrice}>{price !== null && price > 0n ? usd(price, m.unknown) : m.priceUnavailable}</Datum>
                <Datum label={m.priceUpdated}>{readableTime(priceAt, m.unknown, locale)}</Datum>
              </dl>
              {priceStale && <p style={notice}>{m.errStalePrice}</p>}
            </div>

            <section style={card} aria-label={m.myPosition}>
              <div style={{ display: "flex", gap: 8, justifyContent: "space-between", alignItems: "center", flexWrap: "wrap" }}>
                <h3 style={{ margin: 0, fontSize: 16 }}>{m.myPosition}</h3>
                {badge}
              </div>
              {!account ? <p style={muted}>{m.connectToSee}</p> : (
                <>
                  <dl style={{ ...columns, margin: 0 }}>
                    <Datum label={m.vleiRole}>{roleLabel}</Datum>
                    <Datum label={m.vleiExpiry}>{readableTime(expiresAt, m.unknown, locale)}</Datum>
                    <Datum label={m.myContribution}>{bnb(contribution, m.unknown)}</Datum>
                    <Datum label={m.claimable}>{claimable === null ? m.unknown : decimalAmount(claimable)}</Datum>
                    <Datum label={m.remainingCap}>{usd(remainingCap, m.unknown)}</Datum>
                  </dl>
                  {!verified && vleiStatus !== null && (<><p style={notice}>{vleiReason}</p><KybPortalHint m={m} /></>)}
                </>
              )}
            </section>

            {canTransact && (
              <section style={{ display: "grid", gap: 12 }} aria-label={m.participation}>
                <h3 style={{ margin: 0, fontSize: 17 }}>{m.participation}</h3>
                {open && (
                  <div style={{ display: "grid", gap: 8 }}>
                    <div style={{ ...columns, alignItems: "end" }}>
                      <Field label={m.contributionAmount}>
                        <input name="contribution" value={amount} inputMode="decimal" maxLength={26} disabled={busy || waiting}
                          style={input} onChange={event => { setAmount(event.target.value); setReview(null); setError(null); }} />
                      </Field>
                      {remainingTarget > 0n && (
                        <button type="button" disabled={busy || waiting} style={buttonStyle(busy || waiting, true)}
                          onClick={() => { setAmount(decimalAmount(remainingTarget)); setReview(null); }}>{m.fillRemaining}</button>
                      )}
                    </div>
                    <p style={muted}>{m.usdPreview} {usd(inputUsd, m.unknown)} · {m.remainingCap} {usd(remainingCap, m.unknown)}</p>
                    {excessWei > 0n && <p style={muted}>{m.excessRefunded} {bnb(excessWei, m.unknown)}</p>}
                    {fillsTarget && <p style={{ ...muted, color: ink, fontWeight: 700 }}>{m.launchGasNotice} {LAUNCH_GAS_HINT}</p>}
                    <p style={muted}>{m.contributionHelp}</p>
                  </div>
                )}
                {review && (
                  <div style={{ ...card, gap: 10 }}>
                    <h4 style={{ margin: 0 }}>{labels[review.action]}</h4>
                    <p style={muted}>{reviewStale ? m.reviewChanged : m.confirmReady}</p>
                    {helps[review.action] && <p style={muted}>{helps[review.action]}</p>}
                    {review.valueWei && <p style={mono}>{bnb(asUnits(review.valueWei), m.unknown)} → {m.accepted} {bnb(acceptedWei, m.unknown)} ≈ {usd(inputUsd, m.unknown)}</p>}
                    {review.action === "contribute" && excessWei > 0n && <p style={muted}>{m.excessRefunded} {bnb(excessWei, m.unknown)}</p>}
                    {review.action === "contribute" && fillsTarget && <p style={{ ...muted, color: ink, fontWeight: 700 }}>{m.launchGasNotice} {LAUNCH_GAS_HINT}</p>}
                    <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
                      <button type="button" disabled={busy || reviewStale} style={buttonStyle(busy || reviewStale)} onClick={() => void confirmAction()}>
                        {busy ? m.working : m.confirmTransaction}
                      </button>
                      <button type="button" disabled={busy} style={buttonStyle(busy, true)} onClick={() => setReview(null)}>{m.back}</button>
                    </div>
                  </div>
                )}
                {!review && !waiting && (
                  !account ? (
                    <button type="button" style={{ ...buttonStyle(), justifySelf: "start" }} onClick={() => host?.wallet?.connect()}>{m.connectWallet}</button>
                  ) : wrongChain ? (
                    <button type="button" disabled={busy} style={{ ...buttonStyle(busy), justifySelf: "start" }} onClick={() => void switchChain()}>{m.switchChain}</button>
                  ) : visibleActions.length === 0 ? <p style={muted}>{m.noActions}</p> : (
                    <div style={{ display: "grid", gap: 8 }}>
                      {visibleActions.map(action => (
                        <div key={action} style={{ display: "flex", gap: 10, alignItems: "center", flexWrap: "wrap" }}>
                          <button type="button" disabled={busy || !ready(action)} style={buttonStyle(busy || !ready(action))}
                            onClick={() => startAction(action)}>{busy ? m.working : labels[action]}</button>
                          {!gates[action].enabled && gates[action].reason && <span style={notice}>{gates[action].reason}</span>}
                        </div>
                      ))}
                    </div>
                  )
                )}
                {error && <p role="alert" style={notice}>{error}</p>}
                <ReceiptStatus receipt={receipt} m={m} />
                <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
                  {waiting && host?.checkReceipt && <button type="button" disabled={busy} style={buttonStyle(busy)}
                    onClick={() => void checkAction()}>{m.checkReceipt}</button>}
                  {host?.refresh && <button type="button" disabled={busy} style={buttonStyle(busy, true)}
                    onClick={() => host?.refresh?.()}>{m.refresh}</button>}
                </div>
              </section>
            )}
            {!canTransact && <p style={muted}>{m.readOnlyNotice}</p>}
            {launched && token && host?.redirect && (
              <button type="button" style={{ ...buttonStyle(false, true), justifySelf: "start" }}
                onClick={() => host?.redirect?.("/bnb-testnet/" + token.toLowerCase())}>{m.openToken}</button>
            )}
          </>
        )}
        <details style={{ borderBlockStart: `1px solid ${rule}`, paddingBlockStart: 12 }}>
          <summary style={{ fontWeight: 700, cursor: "pointer" }}>{m.contracts}</summary>
          <dl style={{ margin: "12px 0 0", display: "grid", gap: 12 }}>
            <Datum label={m.factory}>{identity.factoryAddress}</Datum>
            {launcherAddress && <Datum label={m.launcher}>{launcherAddress}</Datum>}
            {s?.creator && <Datum label={m.creator}>{s.creator}</Datum>}
          </dl>
        </details>
      </div>
    </section>
  );
}
