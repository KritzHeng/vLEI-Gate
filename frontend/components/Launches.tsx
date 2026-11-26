"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { useDemo } from "@/lib/demo";
import { formatUnits, parseUnits, zeroAddress, type Address } from "viem";
import { erc20Abi, launcherAbi, vaultLauncherV2Abi, vaultV2Abi } from "@/lib/abis";
import { backend, type PriceCheck } from "@/lib/backend";
import {
  ADDRESSES_CONFIGURED,
  FACTORY_ADDRESSES,
  IS_TESTNET,
  PORTAL_ADDRESS,
  PRICE_FEED_FACTORY_ADDRESS,
  QUOTE_TOKEN_ADDRESS,
  addressUrl,
} from "@/lib/config";
import { explainError } from "@/lib/errors";
import { fmtAmount, fmtTime, fmtUsd18, short } from "@/lib/format";
import { KIND_LABEL, loadAll, taxDestination, type FactoryView, type LaunchView, type Quote } from "@/lib/launches";
import { useSession } from "@/lib/session";
import { useTx, type TxState } from "@/lib/tx";
import { useWallet } from "@/lib/wallet";
import AddToken from "./AddToken";
import { isLiveRisk, needsConfirmation } from "./RiskGate";
import TxStatus from "./TxStatus";

export type { LaunchView, Mine } from "@/lib/launches";

export const STATUS = ["Raising", "Launched", "Failed (refunds open)", "Cancelled"] as const;
export const STATUS_CLS = ["info", "ok", "bad", "neutral"] as const;
export const VLEI_STATUS = ["not registered", "active", "expired", "wallet revoked", "entity revoked"] as const;
/** The contribution that reaches the target launches the token and needs gasleft >= MIN_LAUNCH_GAS (7M). */
export const LAUNCH_GAS = 9_000_000n;
const MAX_UINT = 2n ** 256n - 1n;

export function useLaunches() {
  const w = useWallet();
  const [launches, setLaunches] = useState<LaunchView[]>([]);
  const [factories, setFactories] = useState<FactoryView[]>([]);
  const [loading, setLoading] = useState(false);
  const [loaded, setLoaded] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [tick, setTick] = useState(0);
  useEffect(() => {
    if (!ADDRESSES_CONFIGURED) return;
    let live = true;
    setLoading(true);
    loadAll(w.account)
      .then((res) => {
        if (!live) return;
        setFactories(res.flatMap((r) => (r.factory ? [r.factory] : [])));
        setLaunches(res.flatMap((r) => r.launches));
        const errs = res.filter((r) => r.error).map((r) => explainError(r.error));
        setErr(errs.length ? errs.join(" · ") : null);
      })
      .catch((e) => live && setErr(explainError(e)))
      .finally(() => {
        if (!live) return;
        setLoading(false);
        setLoaded(true);
      });
    return () => {
      live = false;
    };
  }, [w.account, w.refreshKey, tick]);
  return {
    launches,
    factories,
    loading,
    loaded,
    err,
    reload: () => setTick((t) => t + 1),
  };
}

export function Addr({ a }: { a: Address }) {
  if (a === zeroAddress) return <span className="muted">—</span>;
  const url = addressUrl(a);
  return url ? (
    <a className="mono" href={url} target="_blank" rel="noreferrer">
      {short(a, 4)}
    </a>
  ) : (
    <span className="mono">{short(a, 4)}</span>
  );
}

/** All quotes (BNB, USDT) and launch tokens have 18 decimals (the v2 factory enforces it for ERC20 quotes). */
export const amt = (v: bigint, q: Quote | string, d = 2) => fmtAmount(v, typeof q === "string" ? q : q.symbol, d);
const parse = (s: string): bigint | null => {
  try {
    return parseUnits((s || "0").trim(), 18);
  } catch {
    return null;
  }
};
const fmtIn = (v: bigint) => formatUnits(v, 18);
export const busy = (s: TxState) => ["simulating", "signing", "pending"].includes(s.phase);
const min = (a: bigint, b: bigint) => (a < b ? a : b);
const hint = (r: string | null | false | undefined) => (r ? <span className="hint">{r}</span> : null);

/** Launcher's view of the connected wallet: 1 active, 2 expired, 3 wallet revoked, 4 entity revoked, 0 none. */
export const vleiOf = (l: LaunchView) => l.mine?.vleiStatus ?? -1;
export const isRevoked = (l: LaunchView) => vleiOf(l) === 3 || vleiOf(l) === 4;

export type Tab = "sale" | "stake" | "rewards";

/** Launches whose BNB value is priced on-chain by the Atlas signed feed (the price-feed factory, native quote). */
export const isAtlasPriced = (l: LaunchView) =>
  l.quote.native && !!PRICE_FEED_FACTORY_ADDRESS && l.factory.toLowerCase() === PRICE_FEED_FACTORY_ADDRESS.toLowerCase();

const UNREACHABLE: PriceCheck = {
  status: "unavailable",
  ok: false,
  reason: "price check service unreachable",
  deviationBps: null,
  maxDeviationBps: 0,
  maxAgeSeconds: 0,
  checkedAt: 0,
  atlas: null,
  cmc: null,
};

/** Atlas vs CoinMarketCap cross-check, refreshed every 60 s. null while loading; fails closed on errors. */
function usePriceCheck(enabled: boolean): PriceCheck | null {
  const [pc, setPc] = useState<PriceCheck | null>(null);
  useEffect(() => {
    if (!enabled) return;
    let live = true;
    const load = () =>
      backend
        .priceCheck()
        .then((r) => live && setPc(r))
        .catch(() => live && setPc(UNREACHABLE));
    load();
    const id = setInterval(load, 60_000);
    return () => {
      live = false;
      clearInterval(id);
    };
  }, [enabled]);
  return pc;
}

const usdP = (v: number) => `$${v.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;

function PriceCheckLine({ pc }: { pc: PriceCheck | null }) {
  if (!pc) return <div className="small muted">Checking Atlas vs CoinMarketCap price…</div>;
  return (
    <div className="small" role="status" aria-live="polite">
      <span className={`badge ${pc.ok ? "ok" : "bad"}`}>{pc.ok ? "Price check passed" : "Price check failed"}</span>{" "}
      <span className="muted">
        Atlas {pc.atlas ? usdP(pc.atlas.price) : "—"} · CoinMarketCap {pc.cmc ? usdP(pc.cmc.price) : "—"}
        {pc.deviationBps !== null && (
          <>
            {" "}
            · Δ {(pc.deviationBps / 100).toFixed(2)}% (max {(pc.maxDeviationBps / 100).toFixed(0)}%)
          </>
        )}
        {!pc.ok && <> · {pc.reason}</>}
      </span>
    </div>
  );
}

// ---------------------------------------------------------------------------------------------------------------------
// Sale (launcher): contribute, claim allocation, withdraw / refund / cancel
// ---------------------------------------------------------------------------------------------------------------------

export function SalePanel({ l, riskConfirmed }: { l: LaunchView; riskConfirmed: boolean }) {
  const { risk } = useSession();
  const { demo } = useDemo();
  const w = useWallet();
  const tx = useTx();
  const left = l.target - l.raised;
  const q = l.quote;
  const m = l.mine;
  // ERC20: an empty amount means "max" and uses the no-arg contribute(); native BNB needs an explicit value.
  const [amount, setAmount] = useState(() =>
    q.native ? fmtIn(m && m.maxContribution > 0n ? min(m.maxContribution, left) : left) : "",
  );
  const [mintAmount, setMintAmount] = useState("5000");
  // Cournot rate-risk gate, fail closed: no live assessment loaded -> no contribution.
  const liveRisk = isLiveRisk(risk) ? risk : null;
  const blocked = needsConfirmation(liveRisk, riskConfirmed);
  const L = {
    address: l.address,
    abi: l.kind === "v1" ? launcherAbi : vaultLauncherV2Abi,
  } as const;
  const maxMode = !q.native && amount.trim() === "";
  const value = maxMode ? null : parse(amount);
  const canMint = demo && IS_TESTNET && !q.native && q.address.toLowerCase() === QUOTE_TOKEN_ADDRESS.toLowerCase();
  const maxAvail = m ? min(min(m.maxContribution, left), q.native ? m.maxContribution : m.quoteBalance) : left;
  const need = maxMode ? maxAvail : (value ?? 0n);
  const needsApprove = !q.native && !!m && need > 0n && m.quoteAllowance < need;
  const atlasPriced = isAtlasPriced(l);
  const pc = usePriceCheck(atlasPriced && l.status === 0);

  const contributeNative = () => {
    if (value === null) return;
    // Excess over the target is refunded; fixed gas on the launching contribution instead of the wallet's estimate.
    tx.run({
      ...L,
      functionName: "contribute",
      value,
      gas: value >= left ? LAUNCH_GAS : undefined,
    });
  };
  /** No-arg contribute(): pulls min(allowance, balance, target − raised, entity cap left) = previewContribute. */
  const contributeErc20 = () => {
    const pulls = l.mine?.previewContribute ?? 0n;
    tx.run({
      ...L,
      functionName: "contribute",
      gas: pulls >= left && pulls > 0n ? LAUNCH_GAS : undefined,
    });
  };
  /** contributeAmount(amount): exactly amount (clamped to target − raised). */
  const contributeAmount = () => {
    if (value === null) return;
    tx.run({
      ...L,
      functionName: "contributeAmount",
      args: [value],
      gas: value >= left ? LAUNCH_GAS : undefined,
    });
  };
  const approve = () =>
    tx.run({
      address: q.address,
      abi: erc20Abi,
      functionName: "approve",
      args: [l.address, need],
    });

  const contributeReason = !w.account
    ? "Connect your wallet first."
    : !liveRisk
      ? "Waiting for the Cournot rate-risk assessment (see the notice on this page)."
      : blocked
        ? "Review and confirm the rate-risk notice on this page first."
        : atlasPriced && !pc
          ? "Checking the Atlas and CoinMarketCap prices…"
          : atlasPriced && pc && !pc.ok
            ? `Contributions paused: ${pc.reason}.`
            : value === null && !maxMode
              ? "Enter a valid amount."
              : null;
  const stateHint =
    l.status !== 0
      ? `The sale is ${STATUS[l.status]?.toLowerCase() ?? "closed"}; contributions are closed.`
      : m && m.vleiStatus !== 1
        ? `Your vLEI is ${VLEI_STATUS[m.vleiStatus] ?? "not active"}: verify first or the contribution will be rejected.`
        : null;

  const refundable = !!m && m.contribution > 0n && (l.status === 2 || l.status === 3);
  let primaryLabel: string;
  let primaryRun: () => void;
  if (q.native) {
    primaryLabel = `Contribute ${value !== null ? amt(value, q) : ""}`;
    primaryRun = contributeNative;
  } else if (needsApprove) {
    primaryLabel = `Approve ${amt(need, q)} (1/2)`;
    primaryRun = approve;
  } else if (maxMode) {
    primaryLabel = `Contribute max · ${amt(m?.previewContribute ?? 0n, q)} (2/2)`;
    primaryRun = contributeErc20;
  } else {
    primaryLabel = `Contribute ${value !== null ? amt(value, q) : ""} (2/2)`;
    primaryRun = contributeAmount;
  }

  return (
    <div className="panel">
      {m ? (
        <div className="kvline small">
          <span>
            Contributed <b>{amt(m.contribution, q)}</b>
          </span>
          <span>
            Your {q.symbol} <b>{amt(m.quoteBalance, q)}</b>
          </span>
          {!q.native && (
            <span>
              Approved <b>{m.quoteAllowance === MAX_UINT ? "unlimited" : amt(m.quoteAllowance, q)}</b>
            </span>
          )}
          <span>
            You can still add <b>{amt(min(m.maxContribution, left), q)}</b>
          </span>
          <span>
            Entity cap left <b>{fmtUsd18(m.remainingCapUsd)}</b>
          </span>
        </div>
      ) : (
        <div className="small muted">Connect a wallet to see your balance and contribution.</div>
      )}

      {!refundable ? (
        <>
          <div className="row wrap">
            <label>
              Amount ({q.symbol})
              <input
                value={amount}
                onChange={(e) => setAmount(e.target.value)}
                inputMode="decimal"
                placeholder={q.native ? "0.0" : `max${m ? ` (${amt(m.previewContribute ?? maxAvail, q)})` : ""}`}
                style={{ width: 170 }}
              />
            </label>
            {m && (
              <button
                className="link"
                onClick={() => setAmount(q.native ? fmtIn(min(m.maxContribution, left)) : "")}
                title={
                  q.native
                    ? "fill the max you can contribute"
                    : "empty = max: the no-arg contribute() pulls what you approved, up to your cap"
                }
              >
                max
              </button>
            )}
            <button className="primary" disabled={!!contributeReason || busy(tx.state)} onClick={primaryRun}>
              {primaryLabel}
            </button>
            {hint(contributeReason)}
          </div>
          {hint(stateHint)}
          {atlasPriced && <PriceCheckLine pc={pc} />}
          {!q.native && (
            <div className="small muted">
              {needsApprove
                ? `Step 1 lets the launcher pull ${q.symbol} from your wallet; step 2 contributes it.`
                : maxMode
                  ? "Leave the amount empty to contribute the most you can (approved amount, capped by your entity's limit and the target)."
                  : "Contributes exactly this amount (clamped to what is left of the target)."}
            </div>
          )}
        </>
      ) : null}

      {refundable && (
        <button className="primary" disabled={busy(tx.state)} onClick={() => tx.run({ ...L, functionName: "refund" })}>
          Refund my contribution ({amt(m!.contribution, q)})
        </button>
      )}

      <div className="row wrap">
        <button
          className="secondary"
          disabled={busy(tx.state) || (!!m && m.claimable === 0n)}
          onClick={() => tx.run({ ...L, functionName: "claim" })}
        >
          Claim my {l.symbol} allocation
          {m && m.claimable > 0n ? ` (${amt(m.claimable, l.symbol)})` : ""}
        </button>
        {m &&
          m.claimable === 0n &&
          hint(l.status === 1 ? "No sale allocation left to claim." : "Allocation is claimable after the launch.")}
      </div>
      <div className="small muted">
        This claims launch tokens bought in the sale. Vault yield in {q.symbol} is claimed under <b>Rewards</b> (here or in
        Portfolio).
      </div>

      {canMint && (
        <div className="row wrap">
          <label>
            Test {q.symbol}
            <input
              value={mintAmount}
              onChange={(e) => setMintAmount(e.target.value)}
              inputMode="decimal"
              style={{ width: 110 }}
            />
          </label>
          <button
            className="secondary"
            disabled={!w.account || busy(tx.state) || parse(mintAmount) === null}
            onClick={() =>
              tx.run({
                address: q.address,
                abi: erc20Abi,
                functionName: "mint",
                args: [w.account as Address, parse(mintAmount) as bigint],
              })
            }
          >
            Get test {q.symbol}
          </button>
          <span className="badge mock">DEMO</span>
          <span className="small muted">testnet mock-token faucet</span>
        </div>
      )}

      <details className="tech">
        <summary>More actions</summary>
        <div className="stack-sm">
          <div className="row wrap">
            <button
              className="secondary"
              disabled={busy(tx.state)}
              onClick={() => tx.run({ ...L, functionName: "withdrawContribution" })}
            >
              Withdraw my contribution
            </button>
            <span className="small muted">Before the launch, if your vLEI is no longer active.</span>
          </div>
          <div className="row wrap">
            <button className="secondary" disabled={busy(tx.state)} onClick={() => tx.run({ ...L, functionName: "refund" })}>
              Refund
            </button>
            <span className="small muted">After a failed or cancelled sale.</span>
          </div>
          <div className="row wrap">
            <button
              className="danger"
              disabled={busy(tx.state)}
              onClick={() => tx.run({ ...L, functionName: "cancelIfCreatorRevoked" })}
            >
              Cancel sale (creator revoked)
            </button>
            <span className="small muted">
              Anyone may cancel once the creator&apos;s vLEI is revoked; everyone can then refund.
            </span>
          </div>
          <div className="small muted">
            These calls are also available in the Flap launcher UI. The contribution that reaches the target launches the token on
            the DEX in the same transaction (sent with a {Number(LAUNCH_GAS) / 1e6}M gas limit; MIN_LAUNCH_GAS is 7M)
            {q.native ? "; excess BNB is refunded" : ""}. Left to target: {amt(left, q)}.
            {m && !q.native && <> No-arg contribute() would pull {amt(m.previewContribute ?? 0n, q)} now.</>}
          </div>
        </div>
      </details>
      <TxStatus state={tx.state} />
    </div>
  );
}

// ---------------------------------------------------------------------------------------------------------------------
// Gated vault: Stake / Rewards
// ---------------------------------------------------------------------------------------------------------------------

export function StakePanel({ l }: { l: LaunchView }) {
  const w = useWallet();
  const tx = useTx();
  const v = l.vault!;
  const m = v.mine;
  const sym = l.symbol;
  const [stakeAmt, setStakeAmt] = useState(() => fmtIn(m?.tokenBalance ?? 0n));
  const [unstakeAmt, setUnstakeAmt] = useState(() => fmtIn(m?.stakedOf ?? 0n));
  const V = { address: v.address, abi: vaultV2Abi } as const;
  const s = parse(stakeAmt);
  const u = parse(unstakeAmt);
  const needsApprove = !!m && s !== null && s > 0n && m.tokenAllowance < s;
  const stakeReason = !w.account ? "Connect your wallet first." : s === null || s === 0n ? "Enter an amount to stake." : null;

  return (
    <div className="panel">
      {m ? (
        <div className="kvline small">
          <span>
            In wallet <b>{amt(m.tokenBalance, sym)}</b>
          </span>
          <span>
            Staked <b>{amt(m.stakedOf, sym)}</b>
          </span>
          <span>{m.isEarning ? <span className="badge ok">earning</span> : <span className="badge">not earning</span>}</span>
        </div>
      ) : (
        <div className="small muted">Connect a wallet to see your position.</div>
      )}
      <div className="row wrap">
        <label>
          Stake amount ({sym})
          <input value={stakeAmt} onChange={(e) => setStakeAmt(e.target.value)} inputMode="decimal" style={{ width: 150 }} />
        </label>
        {m && (
          <button className="link" onClick={() => setStakeAmt(fmtIn(m.tokenBalance))}>
            max
          </button>
        )}
        <button
          className="primary"
          disabled={!!stakeReason || busy(tx.state)}
          onClick={() =>
            needsApprove
              ? tx.run({
                  address: v.taxToken,
                  abi: erc20Abi,
                  functionName: "approve",
                  args: [v.address, s as bigint],
                })
              : tx.run({ ...V, functionName: "stake", args: [s as bigint] })
          }
        >
          {needsApprove ? `Approve ${sym} (1/2)` : `Stake ${s ? amt(s, sym) : ""} (2/2)`}
        </button>
        {hint(stakeReason)}
      </div>
      <div className="small muted">
        Staked {sym} earns a share of the trading-tax revenue while your vLEI is active. Minimum stake {amt(v.minStake, sym, 0)}.
      </div>

      <details className="tech">
        <summary>Unstake</summary>
        <div className="row wrap">
          <label>
            Unstake amount ({sym})
            <input
              value={unstakeAmt}
              onChange={(e) => setUnstakeAmt(e.target.value)}
              inputMode="decimal"
              style={{ width: 150 }}
            />
          </label>
          <button
            className="secondary"
            disabled={busy(tx.state) || u === null}
            onClick={() => tx.run({ ...V, functionName: "unstake", args: [u as bigint] })}
          >
            Unstake {u ? amt(u, sym) : ""}
          </button>
        </div>
        <div className="small muted">
          Unstaking returns {sym} to your wallet and stops it earning. It does <b>not</b> pay out rewards: claim those in the
          Rewards tab.
        </div>
      </details>
      <TxStatus state={tx.state} />
    </div>
  );
}

export function RewardsPanel({ l }: { l: LaunchView }) {
  const w = useWallet();
  const tx = useTx();
  const { demo } = useDemo();
  const v = l.vault!;
  const m = v.mine;
  const q = l.quote;
  const sym = l.symbol;
  const V = { address: v.address, abi: vaultV2Abi } as const;
  const claimReason = !w.account
    ? "Connect your wallet first."
    : !m
      ? null
      : isRevoked(l)
        ? "Suspended: your vLEI was revoked. Re-verify to claim."
        : !m.canClaim
          ? m.claimable === 0n
            ? "No rewards to claim yet."
            : "Claiming needs an active vLEI registration."
          : m.claimable === 0n
            ? "No rewards to claim yet."
            : null;

  return (
    <div className="panel">
      <div className="stat">
        <div className="stat-label">Claimable rewards</div>
        <div className="stat-value">{m ? amt(m.claimable, q, 4) : "—"}</div>
      </div>
      <div className="row wrap">
        <button
          className="primary"
          disabled={!!claimReason || busy(tx.state)}
          onClick={() => tx.run({ ...V, functionName: "claim" })}
        >
          Claim {m ? amt(m.claimable, q, 4) : q.symbol}
        </button>
        <button
          className="secondary"
          disabled={busy(tx.state)}
          onClick={() => tx.run({ ...V, functionName: "sync" })}
          title="Account for trading-tax revenue the vault received since the last update"
        >
          Refresh rewards
        </button>
        {!q.native && <AddToken address={q.address} symbol={q.symbol} />}
      </div>
      {hint(claimReason)}
      <div className="small muted">
        Rewards are paid in {q.symbol} only to stakers with an active vLEI. Claiming keeps your {sym} staked. &ldquo;Refresh
        rewards&rdquo; pulls in revenue received since the last update.
      </div>
      <details className="tech" open={demo || undefined}>
        <summary>Vault details</summary>
        <div className="kvline small">
          <span>
            Vault <Addr a={v.address} />
          </span>
          <span>
            Revenue <b>{amt(v.totalRevenue, q)}</b>
          </span>
          <span>
            Paid out <b>{amt(v.totalClaimed, q)}</b>
          </span>
          <span>
            Forfeited <b>{amt(v.totalForfeited, q)}</b>
          </span>
          <span>
            Held (undistributed) <b>{amt(v.undistributed, q)}</b>
          </span>
          <span>
            Total staked <b>{amt(v.totalStaked, sym)}</b>
          </span>
        </div>
        <div className="small muted">
          Held revenue is released once {amt(v.heldReleaseMinStake, sym, 0)} are staked. A revoked staker&apos;s unclaimed{" "}
          {q.symbol} is forfeited to the remaining stakers when they are evicted (Compliance).
        </div>
        {m && (
          <div className="small muted">
            canClaim {String(m.canClaim)} · isEarning {String(m.isEarning)} · evictable {String(m.evictable)} · allowance to vault{" "}
            {m.tokenAllowance === MAX_UINT ? "unlimited" : amt(m.tokenAllowance, sym)}
          </div>
        )}
      </details>
      <TxStatus state={tx.state} />
    </div>
  );
}

/** Tabbed actions for one launch: Sale, and for gated-vault launches Stake / Rewards. */
export function LaunchActions({
  l,
  riskConfirmed,
  tab,
  setTab,
}: {
  l: LaunchView;
  riskConfirmed: boolean;
  tab: Tab;
  setTab: (t: Tab) => void;
}) {
  const tabs: { id: Tab; label: string }[] = [{ id: "sale", label: "Invest" }];
  if (l.vault) tabs.push({ id: "stake", label: "Stake" }, { id: "rewards", label: "Rewards" });
  const active = tabs.some((t) => t.id === tab) ? tab : "sale";
  const idBase = `tabs-${l.address.slice(2, 10)}`;
  return (
    <div className="tabs-wrap">
      <div className="tabs" role="tablist" aria-label={`${l.symbol} actions`}>
        {tabs.map((t) => (
          <button
            key={t.id}
            role="tab"
            id={`${idBase}-${t.id}`}
            aria-selected={active === t.id}
            aria-controls={`${idBase}-panel`}
            className={`tab ${active === t.id ? "active" : ""}`}
            onClick={() => setTab(t.id)}
          >
            {t.label}
          </button>
        ))}
      </div>
      <div role="tabpanel" id={`${idBase}-panel`} aria-labelledby={`${idBase}-${active}`}>
        {active === "sale" && <SalePanel key={`s-${l.address}`} l={l} riskConfirmed={riskConfirmed} />}
        {active === "stake" && <StakePanel key={`k-${l.address}`} l={l} />}
        {active === "rewards" && <RewardsPanel key={`r-${l.address}`} l={l} />}
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------------------------------------------------
// Shared pieces for the Offerings / Portfolio views
// ---------------------------------------------------------------------------------------------------------------------

export function defaultTab(l: LaunchView): Tab {
  if (!l.vault || l.status !== 1) return "sale";
  const m = l.vault.mine;
  if (m && m.claimable > 0n) return "rewards";
  return "stake";
}

/** Red/amber state when the wallet's vLEI is no longer active (the key scene for revocation). */
export function SuspendedBanner({ l }: { l: LaunchView }) {
  const s = vleiOf(l);
  if (s !== 2 && s !== 3 && s !== 4) return null;
  const vm = l.vault?.mine;
  const staked = !!vm && vm.stakedOf > 0n;
  if (s === 2) {
    return (
      <div className="alert warn" role="status">
        <div className="alert-title">
          {l.vault ? "Rewards paused — your vLEI registration expired" : "Your vLEI registration expired"}
        </div>
        <div>Verify again to resume {l.vault ? "earning and claiming" : "investing"}.</div>
        <Link className="btn primary" href="/verify">
          Re-verify now
        </Link>
      </div>
    );
  }
  return (
    <div className="alert bad" role="alert">
      <div className="alert-title">{l.vault ? "Rewards suspended — your vLEI was revoked" : "Your vLEI was revoked"}</div>
      <div>
        {s === 4 ? "Your organisation's vLEI credential was revoked" : "This wallet's registration was revoked"}, so it can no
        longer contribute, claim or earn.{" "}
        {staked && vm && (
          <>
            Your {amt(vm.stakedOf, l.symbol)} stopped earning, and your unclaimed {amt(vm.claimable, l.quote, 4)} goes to the
            other verified stakers if you are evicted.{" "}
          </>
        )}
        <b>Re-verify to restore {l.vault ? "your rewards" : "access"}.</b>
        {s === 4 && <> (A compliance admin must reinstate the entity first.)</>}
      </div>
      <Link className="btn primary" href="/verify">
        Re-verify
      </Link>
    </div>
  );
}

/** Demo-mode table of every configured factory (raw addresses, type, quote, Portal status). */
export function FactoryTable({ factories, launches }: { factories: FactoryView[]; launches: LaunchView[] }) {
  if (factories.length === 0)
    return <div className="muted small">No factories loaded ({FACTORY_ADDRESSES.length} configured).</div>;
  return (
    <>
      <div className="small muted">
        Every launcher created through <span className="mono">Portal.newLauncher</span> with the vLEI factories (Portal{" "}
        <Addr a={PORTAL_ADDRESS} />) · {factories.length} factories · {launches.length} launchers.
      </div>
      <div className="table-scroll">
        <table className="table stacked">
          <thead>
            <tr>
              <th>Factory</th>
              <th>Type</th>
              <th>Quote</th>
              <th>Launchers</th>
              <th>Enabled on Portal</th>
              <th>Tax yield</th>
            </tr>
          </thead>
          <tbody>
            {factories.map((f, i) => (
              <tr key={f.address}>
                <td data-label="Factory" className="small">
                  <Addr a={f.address} /> {i === 0 && <span className="badge ok">primary</span>}
                </td>
                <td data-label="Type" className="small">
                  {KIND_LABEL[f.kind]}
                </td>
                <td data-label="Quote" className="small">
                  {f.quote.symbol} {!f.quote.native && <Addr a={f.quote.address} />}
                </td>
                <td data-label="Launchers" className="small">
                  {f.launchers.length}
                </td>
                <td data-label="On Portal" className="small">
                  {f.portalEnabled === null ? (
                    "—"
                  ) : f.portalEnabled ? (
                    <span className="badge ok">yes</span>
                  ) : (
                    <span className="badge">no</span>
                  )}
                </td>
                <td data-label="Tax yield" className="small">
                  {taxDestination(f.kind, f.quote)}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </>
  );
}
