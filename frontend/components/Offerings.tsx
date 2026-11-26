"use client";

import Link from "next/link";
import { useEffect, useMemo, useState, type ReactNode } from "react";
import type { Address } from "viem";
import { launcherAbi, registryAbi, vaultLauncherV2Abi, vaultV2Abi } from "@/lib/abis";
import { backend, type Persona } from "@/lib/backend";
import { publicClient } from "@/lib/clients";
import { ADDRESSES_CONFIGURED, REGISTRY_ADDRESS } from "@/lib/config";
import { useDemo } from "@/lib/demo";
import { fmtTime, fmtUsd18, leiToHash, short } from "@/lib/format";
import { taxDestination, type LaunchView } from "@/lib/launches";
import { useSession } from "@/lib/session";
import { useTx } from "@/lib/tx";
import { useWallet } from "@/lib/wallet";
import AddToken from "./AddToken";
import {
  Addr,
  FactoryTable,
  LaunchActions,
  STATUS,
  STATUS_CLS,
  SuspendedBanner,
  VLEI_STATUS,
  amt,
  busy,
  defaultTab,
  isRevoked,
  useLaunches,
  vleiOf,
  type Tab,
} from "./Launches";
import RegistryStatus from "./RegistryStatus";
import RiskGate from "./RiskGate";
import TxStatus from "./TxStatus";

// ---------------------------------------------------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------------------------------------------------

/** v1 (BNB) launchers and failed / cancelled sales are listed under "Past offerings". */
export const isPast = (l: LaunchView) => l.kind === "v1" || l.status === 2 || l.status === 3;

/** Featured: a launched gated-vault offering, else any gated-vault one, else the newest. */
export function pickFeatured(list: LaunchView[]): LaunchView | null {
  return list.find((l) => l.vault && l.status === 1) ?? list.find((l) => l.vault) ?? list[0] ?? null;
}

export function kindLabel(l: LaunchView): string {
  return l.kind === "vault-v2" ? "Gated yield vault" : l.kind === "v2" ? "Standard offering" : "Legacy · BNB";
}

export const pctOf = (l: LaunchView) => (l.target > 0n ? Number((l.raised * 10000n) / l.target) / 100 : 0);

export function hasPosition(l: LaunchView): boolean {
  const m = l.mine;
  const vm = l.vault?.mine;
  return (
    (!!m && (m.contribution > 0n || m.claimable > 0n || m.tokenBalance > 0n)) ||
    (!!vm && (vm.stakedOf > 0n || vm.claimable > 0n))
  );
}

export type Issuer = { entity: string | null; lei: string | null };

/** Issuer entity names: the creator's on-chain leiHash matched against the LEIs of the sample credentials. */
export function useIssuers(creators: readonly Address[]) {
  const { verified } = useSession();
  const [map, setMap] = useState<Record<string, Issuer>>({});
  const key = [...new Set(creators.map((c) => c.toLowerCase()))].sort().join(",");
  useEffect(() => {
    if (!key || !ADDRESSES_CONFIGURED) return;
    let live = true;
    (async () => {
      const personas = await backend.personas().catch(() => [] as Persona[]);
      const byHash = new Map(personas.map((p) => [leiToHash(p.lei).toLowerCase(), p]));
      const out: Record<string, Issuer> = {};
      await Promise.all(
        key.split(",").map(async (c) => {
          try {
            const reg = await publicClient.readContract({
              address: REGISTRY_ADDRESS,
              abi: registryAbi,
              functionName: "getRegistration",
              args: [c as Address],
            });
            const p = byHash.get(reg.leiHash.toLowerCase());
            out[c] = { entity: p?.entity ?? null, lei: p?.lei ?? null };
          } catch {
            out[c] = { entity: null, lei: null };
          }
        }),
      );
      if (live) setMap(out);
    })();
    return () => {
      live = false;
    };
  }, [key]);
  return (creator: Address): Issuer => {
    if (verified && verified.wallet.toLowerCase() === creator.toLowerCase()) return { entity: verified.entity_name, lei: verified.lei };
    return map[creator.toLowerCase()] ?? { entity: null, lei: null };
  };
}

// ---------------------------------------------------------------------------------------------------------------------
// Small presentational pieces
// ---------------------------------------------------------------------------------------------------------------------

export function StatusPill({ l }: { l: LaunchView }) {
  return <span className={`badge ${STATUS_CLS[l.status] ?? ""}`}>{STATUS[l.status] ?? l.status}</span>;
}

export function IssuerLine({ l, issuer }: { l: LaunchView; issuer: Issuer }) {
  return (
    <div className="issuer">
      <span className="issuer-avatar" aria-hidden>
        {(issuer.entity ?? "?").slice(0, 1)}
      </span>
      <span className="issuer-name">{issuer.entity ?? <>Issuer {short(l.creator, 4)}</>}</span>
      {l.creatorActive ? (
        <span className="badge ok" title="The issuer's vLEI registration is active on-chain">
          ✓ Verified issuer
        </span>
      ) : (
        <span className="badge bad" title="The issuer's vLEI is no longer active: contributions are paused">
          Issuer not verified
        </span>
      )}
    </div>
  );
}

export function RaiseProgress({ l, large }: { l: LaunchView; large?: boolean }) {
  const pct = pctOf(l);
  return (
    <div className="raise">
      <div className="row between small">
        <span>
          <b className="num">{amt(l.raised, l.quote, 0)}</b> <span className="muted">of {amt(l.target, l.quote, 0)}</span>
        </span>
        <span className="muted num">{pct.toFixed(0)}%</span>
      </div>
      <div
        className={`progress ${large ? "lg" : ""}`}
        role="progressbar"
        aria-valuemin={0}
        aria-valuemax={100}
        aria-valuenow={Math.round(pct)}
        aria-label="Raised of target"
      >
        <div style={{ width: `${Math.min(100, pct)}%` }} />
      </div>
    </div>
  );
}

function CardSkeleton({ featured }: { featured?: boolean }) {
  return (
    <div className={`card offering ${featured ? "featured" : ""}`} aria-busy="true">
      <div className="skel" style={{ width: "45%" }} />
      <div className="skel" style={{ width: "70%", height: 22 }} />
      <div className="skel" style={{ height: 8 }} />
      <div className="skel" style={{ width: "60%" }} />
    </div>
  );
}

export function OfferingCard({ l, issuer, featured }: { l: LaunchView; issuer: Issuer; featured?: boolean }) {
  const { demo } = useDemo();
  const vm = l.vault?.mine;
  const mine = hasPosition(l);
  const href = `/offerings/${l.address}`;
  return (
    <article className={`card offering ${featured ? "featured" : ""}`}>
      {featured && <div className="eyebrow">Featured offering</div>}
      <IssuerLine l={l} issuer={issuer} />
      <div className="offering-title">
        <h3>
          <Link href={href} className="stretched">
            {l.name}
          </Link>
        </h3>
        <span className="muted mono-num">{l.symbol}</span>
      </div>
      <div className="row wrap pills">
        <StatusPill l={l} />
        <span className={`badge ${l.vault ? "info" : ""}`}>{kindLabel(l)}</span>
        <span className="badge">Quote {l.quote.symbol}</span>
        {mine && <span className="badge ok">Your position</span>}
        {isRevoked(l) && vm && vm.stakedOf > 0n && <span className="badge bad">Rewards suspended</span>}
      </div>
      {featured && <p className="small muted">{taxDestination(l.kind, l.quote)}</p>}
      <RaiseProgress l={l} large={featured} />
      <dl className="facts">
        <div>
          <dt>Cap per entity</dt>
          <dd className="num">{fmtUsd18(l.capUsdPerEntity, 0)}</dd>
        </div>
        <div>
          <dt>Yield paid</dt>
          <dd className="num">{l.vault ? amt(l.vault.totalClaimed, l.quote) : <span className="muted">Not gated</span>}</dd>
        </div>
        <div>
          <dt>{l.status === 0 ? "Closes" : "Status"}</dt>
          <dd>{l.status === 0 ? fmtTime(l.deadline) : STATUS[l.status]}</dd>
        </div>
      </dl>
      {demo && (
        <div className="small muted mono-soft">
          launcher {short(l.address, 4)} · creator {short(l.creator, 4)}
        </div>
      )}
      <div className="row">
        <Link href={href} className={`btn ${featured ? "primary" : "secondary"}`}>
          View offering →
        </Link>
      </div>
    </article>
  );
}

export function Empty({ title, children }: { title: string; children?: ReactNode }) {
  return (
    <div className="empty">
      <div className="empty-title">{title}</div>
      {children && <div className="small muted">{children}</div>}
    </div>
  );
}

// ---------------------------------------------------------------------------------------------------------------------
// /offerings
// ---------------------------------------------------------------------------------------------------------------------

export default function OfferingsView() {
  const { demo } = useDemo();
  const { launches, factories, loading, loaded, err, reload } = useLaunches();
  const issuerOf = useIssuers(launches.map((l) => l.creator));
  const current = launches.filter((l) => !isPast(l));
  const past = launches.filter(isPast);
  const featured = pickFeatured(current);
  const others = current.filter((l) => l !== featured);
  const showSkeleton = ADDRESSES_CONFIGURED && !loaded;

  return (
    <div className="stack-lg">
      <div className="page-head">
        <div>
          <h1>Offerings</h1>
          <p className="lead">
            Tokenized asset offerings open only to verified legal entities. Each launch enforces a cap per entity, and gated
            vaults pay trading-tax yield only to verified stakers.
          </p>
        </div>
        <button className="secondary btn-sm" onClick={reload} disabled={loading}>
          {loading ? "Refreshing…" : "Refresh"}
        </button>
      </div>

      {!ADDRESSES_CONFIGURED && <div className="status bad">Contract addresses are not configured.</div>}
      {err && (
        <div className="status bad" role="alert">
          Some offerings could not be loaded: {err}
        </div>
      )}

      {showSkeleton ? (
        <>
          <CardSkeleton featured />
          <div className="card-grid">
            <CardSkeleton />
            <CardSkeleton />
          </div>
        </>
      ) : current.length === 0 ? (
        <Empty title="No open offerings right now">
          {past.length > 0 ? "Past offerings are listed below." : "New offerings appear here once a verified issuer creates one."}
        </Empty>
      ) : (
        <>
          {featured && <OfferingCard l={featured} issuer={issuerOf(featured.creator)} featured />}
          {others.length > 0 && (
            <div className="card-grid">
              {others.map((l) => (
                <OfferingCard key={l.address} l={l} issuer={issuerOf(l.creator)} />
              ))}
            </div>
          )}
        </>
      )}

      {loaded && past.length > 0 && (
        <section className="stack" aria-labelledby="past-h">
          <div>
            <h2 id="past-h">Past offerings</h2>
            <p className="small muted">Earlier pilots (BNB-quoted v1 launchers) and sales that failed or were cancelled. Refunds stay available on each page.</p>
          </div>
          <div className="card-grid past">
            {past.map((l) => (
              <OfferingCard key={l.address} l={l} issuer={issuerOf(l.creator)} />
            ))}
          </div>
        </section>
      )}

      {demo && loaded && (
        <section className="card">
          <div className="row between wrap">
            <h2>Launcher factories</h2>
            <span className="badge mock">DEMO</span>
          </div>
          <FactoryTable factories={factories} launches={launches} />
        </section>
      )}
    </div>
  );
}

// ---------------------------------------------------------------------------------------------------------------------
// /offerings/[launcher]
// ---------------------------------------------------------------------------------------------------------------------

export function OfferingDetail({ address }: { address: string }) {
  const { launches, loaded, err } = useLaunches();
  const l = launches.find((x) => x.address.toLowerCase() === address.toLowerCase()) ?? null;
  const creators = useMemo(() => (l ? [l.creator] : []), [l?.creator]); // eslint-disable-line react-hooks/exhaustive-deps
  const issuerOf = useIssuers(creators);

  if (!l) {
    return (
      <div className="stack-lg">
        <Link href="/offerings" className="back">
          ← All offerings
        </Link>
        {!loaded && ADDRESSES_CONFIGURED ? (
          <div className="detail-grid" aria-busy="true">
            <div className="stack">
              <CardSkeleton featured />
              <CardSkeleton />
            </div>
            <CardSkeleton />
          </div>
        ) : (
          <Empty title="Offering not found">
            {err ? `Could not load offerings: ${err}` : `No offering at ${short(address, 6)} on the configured factories.`}{" "}
            <Link href="/offerings">Browse offerings</Link>
          </Empty>
        )}
      </div>
    );
  }
  return <DetailBody key={l.address} l={l} issuer={issuerOf(l.creator)} />;
}

function DetailBody({ l, issuer }: { l: LaunchView; issuer: Issuer }) {
  const w = useWallet();
  const { demo } = useDemo();
  const tx = useTx();
  const [riskConfirmed, setRiskConfirmed] = useState(false);
  const [tab, setTab] = useState<Tab>(() => defaultTab(l));
  const q = l.quote;
  const vm = l.vault?.mine ?? null;
  const m = l.mine;
  const s = vleiOf(l);
  const L = { address: l.address, abi: l.kind === "v1" ? launcherAbi : vaultLauncherV2Abi } as const;

  // One context-dependent next step.
  let action: { label: string; run?: () => void; href?: string } | null = null;
  if (!w.account) action = { label: "Connect wallet", run: w.connect };
  else if (s === 2 || s === 3 || s === 4) action = { label: "Re-verify to restore", href: "/verify" };
  else if (s === 0) action = { label: "Verify your organisation first", href: "/verify" };
  else if (m && m.contribution > 0n && (l.status === 2 || l.status === 3))
    action = { label: `Refund ${amt(m.contribution, q)}`, run: () => tx.run({ ...L, functionName: "refund" }) };
  else if (l.status === 0) action = { label: "Invest", run: () => setTab("sale") };
  else if (l.status === 1 && m && m.claimable > 0n)
    action = { label: `Claim ${amt(m.claimable, l.symbol)} allocation`, run: () => tx.run({ ...L, functionName: "claim" }) };
  else if (l.vault && vm && vm.claimable > 0n && vm.canClaim)
    action = {
      label: `Claim ${amt(vm.claimable, q, 4)} yield`,
      run: () => tx.run({ address: l.vault!.address, abi: vaultV2Abi, functionName: "claim" }),
    };
  else if (l.vault && vm && vm.tokenBalance > 0n) action = { label: `Stake ${amt(vm.tokenBalance, l.symbol)}`, run: () => setTab("stake") };
  else if (l.vault && vm && vm.stakedOf > 0n) action = { label: "View rewards", run: () => setTab("rewards") };

  return (
    <div className="stack-lg">
      <Link href="/offerings" className="back">
        ← All offerings
      </Link>
      <div className="detail-grid">
        <div className="stack">
          <section className="card detail-hero" aria-labelledby="offering-title">
            <IssuerLine l={l} issuer={issuer} />
            <div className="offering-title">
              <h1 id="offering-title">{l.name}</h1>
              <span className="muted mono-num">{l.symbol}</span>
            </div>
            <div className="row wrap pills">
              <StatusPill l={l} />
              <span className={`badge ${l.vault ? "info" : ""}`}>{kindLabel(l)}</span>
              <span className="badge">Quote {q.symbol}</span>
              {vm?.isEarning && <span className="badge ok">● Earning yield</span>}
            </div>
            <p className="small muted">{taxDestination(l.kind, q)}</p>
            <RaiseProgress l={l} large />
            <SuspendedBanner l={l} />
            <div className="stats">
              <div className="stat">
                <div className="stat-label">You hold</div>
                <div className="stat-value">{m ? amt(m.tokenBalance, l.symbol) : "—"}</div>
              </div>
              {l.vault ? (
                <>
                  <div className="stat">
                    <div className="stat-label">Staked</div>
                    <div className="stat-value">{vm ? amt(vm.stakedOf, l.symbol) : "—"}</div>
                  </div>
                  <div className={`stat ${isRevoked(l) ? "stat-bad" : vm && vm.claimable > 0n ? "stat-ok" : ""}`}>
                    <div className="stat-label">Claimable yield{isRevoked(l) && " (suspended)"}</div>
                    <div className="stat-value">{vm ? amt(vm.claimable, q, 4) : "—"}</div>
                  </div>
                </>
              ) : (
                <>
                  <div className="stat">
                    <div className="stat-label">Contributed</div>
                    <div className="stat-value">{m ? amt(m.contribution, q) : "—"}</div>
                  </div>
                  <div className="stat">
                    <div className="stat-label">Allocation to claim</div>
                    <div className="stat-value">{m ? amt(m.claimable, l.symbol) : "—"}</div>
                  </div>
                </>
              )}
            </div>
            <div className="row wrap">
              {action?.href ? (
                <Link className="btn primary lg" href={action.href}>
                  {action.label}
                </Link>
              ) : action?.run ? (
                <button className="primary lg" disabled={busy(tx.state)} onClick={action.run}>
                  {action.label}
                </button>
              ) : null}
              {hasPosition(l) && (
                <Link className="btn secondary" href="/portfolio">
                  View in portfolio
                </Link>
              )}
            </div>
            <TxStatus state={tx.state} />
          </section>

          <RiskGate confirmed={riskConfirmed} onChange={setRiskConfirmed} />

          <section className="card" aria-label="Actions">
            <LaunchActions l={l} riskConfirmed={riskConfirmed} tab={tab} setTab={setTab} />
          </section>
        </div>

        <aside className="stack">
          <section className="card">
            <h2 className="h-card">Offering terms</h2>
            <dl className="terms">
              <div>
                <dt>Quote token</dt>
                <dd>{q.symbol}</dd>
              </div>
              <div>
                <dt>Target raise</dt>
                <dd className="num">{amt(l.target, q, 0)}</dd>
              </div>
              <div>
                <dt>Raised</dt>
                <dd className="num">{amt(l.raised, q)}</dd>
              </div>
              <div>
                <dt>Cap per legal entity</dt>
                <dd className="num">{fmtUsd18(l.capUsdPerEntity, 0)}</dd>
              </div>
              <div>
                <dt>{l.status === 0 ? "Closes" : "Deadline"}</dt>
                <dd>{fmtTime(l.deadline)}</dd>
              </div>
              <div>
                <dt>Eligibility</dt>
                <dd>Active vLEI registration</dd>
              </div>
            </dl>
            <div className="row wrap">
              {!q.native && <AddToken address={q.address} symbol={q.symbol} />}
              <AddToken address={l.token} symbol={l.symbol} />
            </div>
          </section>

          {l.vault && (
            <section className="card">
              <h2 className="h-card">Yield vault</h2>
              <dl className="terms">
                <div>
                  <dt>Revenue received</dt>
                  <dd className="num">{amt(l.vault.totalRevenue, q)}</dd>
                </div>
                <div>
                  <dt>Paid to verified stakers</dt>
                  <dd className="num">{amt(l.vault.totalClaimed, q)}</dd>
                </div>
                <div>
                  <dt>Forfeited by revoked stakers</dt>
                  <dd className="num">{amt(l.vault.totalForfeited, q)}</dd>
                </div>
                <div>
                  <dt>Total staked</dt>
                  <dd className="num">{amt(l.vault.totalStaked, l.symbol)}</dd>
                </div>
                <div>
                  <dt>Minimum stake</dt>
                  <dd className="num">{amt(l.vault.minStake, l.symbol, 0)}</dd>
                </div>
              </dl>
            </section>
          )}

          <section className="card">
            <RegistryStatus title="Your vLEI registration" />
          </section>

          <section className="card">
            <details className="explainer">
              <summary>How gating works</summary>
              <div className="small stack-sm">
                <p>
                  Anyone can trade the token once it launches. The first-round allocation, and for gated-vault offerings the
                  trading-tax yield, go only to wallets with an active vLEI registration.
                </p>
                <p>
                  Contribute with {q.native ? "BNB" : `${q.symbol}: step 1 approves the launcher to pull ${q.symbol}, step 2 contributes`}.
                  The contribution that reaches the target launches the token on the DEX in the same transaction.
                </p>
                <p>If the issuer&apos;s vLEI is revoked, anyone can cancel the sale and every contributor can refund.</p>
              </div>
            </details>
            <details className="tech" open={demo || undefined}>
              <summary>Technical details</summary>
              <dl className="terms small">
                <div>
                  <dt>Launcher</dt>
                  <dd>
                    <Addr a={l.address} />
                  </dd>
                </div>
                <div>
                  <dt>Token</dt>
                  <dd>
                    <Addr a={l.token} />
                  </dd>
                </div>
                {l.vault && (
                  <div>
                    <dt>Vault</dt>
                    <dd>
                      <Addr a={l.vault.address} />
                    </dd>
                  </div>
                )}
                <div>
                  <dt>Pool</dt>
                  <dd>
                    <Addr a={l.pool} />
                  </dd>
                </div>
                <div>
                  <dt>Creator</dt>
                  <dd>
                    <Addr a={l.creator} /> {l.creatorActive ? "(vLEI active)" : "(paused)"}
                  </dd>
                </div>
                <div>
                  <dt>Factory</dt>
                  <dd>
                    <Addr a={l.factory} />
                  </dd>
                </div>
                {m && (
                  <div>
                    <dt>Your vLEI (launcher view)</dt>
                    <dd>{VLEI_STATUS[m.vleiStatus] ?? m.vleiStatus}</dd>
                  </div>
                )}
              </dl>
            </details>
          </section>
        </aside>
      </div>
    </div>
  );
}
