"use client";

import Link from "next/link";
import { ADDRESSES_CONFIGURED } from "@/lib/config";
import { fmtDuration } from "@/lib/format";
import type { LaunchView } from "@/lib/launches";
import { useWallet } from "@/lib/wallet";
import { RewardsPanel, StakePanel, amt, isRevoked, useLaunches, vleiOf } from "./Launches";
import { Empty, StatusPill, hasPosition, kindLabel } from "./Offerings";
import { identityOf, useRegistryStatus } from "./RegistryStatus";

/** Top-of-page identity alert: big red when revoked, amber when expired, a nudge when never verified. */
function IdentityAlert({ anyStake }: { anyStake: boolean }) {
  const w = useWallet();
  const { status } = useRegistryStatus(w.account);
  if (!status) return null;
  const id = identityOf(status);
  if (id.kind === "revoked") {
    return (
      <div className="alert bad big" role="alert">
        <div className="alert-title">Rewards suspended — your vLEI was revoked. Re-verify to restore.</div>
        <div>
          {status.entityRevoked
            ? "Your organisation's vLEI credential was revoked (a compliance admin must reinstate the entity before you can re-verify)."
            : "This wallet's registration was revoked."}{" "}
          {anyStake
            ? "Staked tokens have stopped earning, and unclaimed yield is forfeited to verified stakers if the position is evicted."
            : "You cannot contribute, claim or earn until you verify again."}
        </div>
        <Link className="btn primary" href="/verify">
          Re-verify
        </Link>
      </div>
    );
  }
  if (id.kind === "expired") {
    return (
      <div className="alert warn big" role="status">
        <div className="alert-title">Rewards paused — your vLEI registration expired.</div>
        <div>Verify again to resume earning and claiming. Your positions are unchanged.</div>
        <Link className="btn primary" href="/verify">
          Renew verification
        </Link>
      </div>
    );
  }
  if (id.kind === "none") {
    return (
      <div className="banner info row wrap between">
        <span>This wallet is not verified yet. Verify your organisation to invest and earn yield.</span>
        <Link className="btn primary btn-sm" href="/verify">
          Verify your organisation
        </Link>
      </div>
    );
  }
  if (id.warn) {
    return (
      <div className="banner warn row wrap between">
        <span>Your vLEI registration expires in {fmtDuration(id.secondsLeft)}. Renew it to keep earning.</span>
        <Link className="btn secondary btn-sm" href="/verify">
          Renew
        </Link>
      </div>
    );
  }
  return null;
}

function Position({ l }: { l: LaunchView }) {
  const m = l.mine;
  const vm = l.vault?.mine ?? null;
  const q = l.quote;
  const revoked = isRevoked(l);
  const s = vleiOf(l);
  const refundable = !!m && m.contribution > 0n && (l.status === 2 || l.status === 3);
  return (
    <article className="card position">
      <div className="row between wrap">
        <div>
          <h3 className="position-title">
            {l.name} <span className="muted mono-num">{l.symbol}</span>
          </h3>
          <div className="row wrap pills">
            <StatusPill l={l} />
            <span className={`badge ${l.vault ? "info" : ""}`}>{kindLabel(l)}</span>
            {vm?.isEarning && <span className="badge ok">● Earning</span>}
            {revoked && <span className="badge bad">Rewards suspended</span>}
            {s === 2 && <span className="badge warn">Paused · expired</span>}
          </div>
        </div>
        <Link className="btn secondary btn-sm" href={`/offerings/${l.address}`}>
          Offering details
        </Link>
      </div>
      <div className="stats four">
        <div className="stat">
          <div className="stat-label">Held</div>
          <div className="stat-value">{m ? amt(m.tokenBalance, l.symbol) : "—"}</div>
        </div>
        <div className="stat">
          <div className="stat-label">Staked</div>
          <div className="stat-value">{vm ? amt(vm.stakedOf, l.symbol) : <span className="muted">n/a</span>}</div>
        </div>
        <div className={`stat ${revoked && vm ? "stat-bad" : vm && vm.claimable > 0n ? "stat-ok" : ""}`}>
          <div className="stat-label">Claimable yield{revoked && vm ? " (suspended)" : ""}</div>
          <div className="stat-value">{vm ? amt(vm.claimable, q, 4) : <span className="muted">n/a</span>}</div>
        </div>
        <div className="stat">
          <div className="stat-label">Contributed</div>
          <div className="stat-value">{m ? amt(m.contribution, q) : "—"}</div>
        </div>
      </div>
      {m && m.claimable > 0n && (
        <div className="banner info row wrap between">
          <span>
            {amt(m.claimable, l.symbol)} of your sale allocation is ready to claim.
          </span>
          <Link className="btn secondary btn-sm" href={`/offerings/${l.address}`}>
            Claim allocation
          </Link>
        </div>
      )}
      {refundable && (
        <div className="banner warn row wrap between">
          <span>This sale did not complete. Your {amt(m!.contribution, q)} can be refunded.</span>
          <Link className="btn secondary btn-sm" href={`/offerings/${l.address}`}>
            Go to refund
          </Link>
        </div>
      )}
      {l.vault && (
        <div className="position-actions">
          <div className="subpanel">
            <h4>Stake</h4>
            <StakePanel l={l} />
          </div>
          <div className="subpanel">
            <h4>Rewards</h4>
            <RewardsPanel l={l} />
          </div>
        </div>
      )}
    </article>
  );
}

export default function PortfolioView() {
  const w = useWallet();
  const { launches, loaded, err } = useLaunches();
  const positions = launches.filter(hasPosition);
  // Featured-first ordering: gated-vault positions first.
  positions.sort((a, b) => Number(!!b.vault) - Number(!!a.vault));
  const anyStake = positions.some((l) => (l.vault?.mine?.stakedOf ?? 0n) > 0n);
  const vaults = positions.filter((l) => l.vault?.mine);
  // Totals per quote symbol (in practice USDT for every gated vault).
  const yieldBySym = new Map<string, bigint>();
  for (const l of vaults) yieldBySym.set(l.quote.symbol, (yieldBySym.get(l.quote.symbol) ?? 0n) + l.vault!.mine!.claimable);
  const yieldText = [...yieldBySym.entries()].map(([sym, v]) => amt(v, sym, 4)).join(" + ") || "—";

  return (
    <div className="stack-lg">
      <div className="page-head">
        <div>
          <h1>Portfolio</h1>
          <p className="lead">Your positions across offerings: tokens held, staked in gated vaults, and yield you can claim.</p>
        </div>
      </div>

      {!w.account ? (
        <div className="empty">
          <div className="empty-title">Connect your wallet to see your portfolio</div>
          <div className="small muted">Positions are read directly from BNB Chain for the connected wallet.</div>
          <button className="primary" onClick={w.connect}>
            {w.hasProvider ? "Connect wallet" : "No wallet found"}
          </button>
        </div>
      ) : (
        <>
          <IdentityAlert anyStake={anyStake} />
          {err && (
            <div className="status bad" role="alert">
              Some offerings could not be loaded: {err}
            </div>
          )}
          {ADDRESSES_CONFIGURED && !loaded ? (
            <div className="stack" aria-busy="true" aria-label="Loading positions">
              <div className="summary-row">
                <div className="skel" style={{ height: 72 }} />
                <div className="skel" style={{ height: 72 }} />
                <div className="skel" style={{ height: 72 }} />
              </div>
              <div className="card">
                <div className="skel" style={{ width: "40%", height: 20 }} />
                <div className="skel" style={{ height: 60 }} />
              </div>
            </div>
          ) : positions.length === 0 ? (
            <Empty title="No positions yet">
              Once you invest in an offering, your holdings, stakes and yield appear here. <Link href="/offerings">Browse offerings</Link>
            </Empty>
          ) : (
            <>
              <div className="summary-row">
                <div className="stat">
                  <div className="stat-label">Positions</div>
                  <div className="stat-value">{positions.length}</div>
                </div>
                <div className="stat">
                  <div className="stat-label">Staked in gated vaults</div>
                  <div className="stat-value">{vaults.filter((l) => l.vault!.mine!.stakedOf > 0n).length}</div>
                </div>
                <div className={`stat ${anyStake && positions.some(isRevoked) ? "stat-bad" : ""}`}>
                  <div className="stat-label">Claimable yield</div>
                  <div className="stat-value">{yieldText}</div>
                </div>
              </div>
              {positions.map((l) => (
                <Position key={l.address} l={l} />
              ))}
            </>
          )}
        </>
      )}
    </div>
  );
}
