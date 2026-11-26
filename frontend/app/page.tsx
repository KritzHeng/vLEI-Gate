"use client";

import Link from "next/link";
import { amt, useLaunches } from "@/components/Launches";
import { isPast } from "@/components/Offerings";
import { ADDRESSES_CONFIGURED } from "@/lib/config";

/** Sum per quote symbol, rendered as "1,234.00 USDT + 0.50 BNB"; "—" when there is nothing to show. */
function sumBySymbol(items: { sym: string; v: bigint }[], digits = 2): string {
  const m = new Map<string, bigint>();
  for (const { sym, v } of items) m.set(sym, (m.get(sym) ?? 0n) + v);
  const parts = [...m.entries()].filter(([, v]) => v > 0n).map(([sym, v]) => amt(v, sym, digits));
  return parts.length ? parts.join(" + ") : items.length ? amt(0n, items[0].sym, digits) : "—";
}

function Stats() {
  const { launches, loaded, err } = useLaunches();
  const ready = ADDRESSES_CONFIGURED && loaded && (launches.length > 0 || !err);
  const vaults = launches.filter((l) => l.vault);
  const stats = [
    { label: "Offerings", value: ready ? `${launches.filter((l) => !isPast(l)).length} open · ${launches.length} total` : "—" },
    { label: "Total raised", value: ready ? sumBySymbol(launches.map((l) => ({ sym: l.quote.symbol, v: l.raised })), 0) : "—" },
    {
      label: "Yield distributed to vaults",
      value: ready ? sumBySymbol(vaults.map((l) => ({ sym: l.quote.symbol, v: l.vault!.totalRevenue }))) : "—",
    },
    {
      label: "Yield claimed by verified stakers",
      value: ready ? sumBySymbol(vaults.map((l) => ({ sym: l.quote.symbol, v: l.vault!.totalClaimed }))) : "—",
    },
  ];
  const loading = ADDRESSES_CONFIGURED && !loaded;
  return (
    <section aria-labelledby="stats-h" className="stack">
      <div className="row between wrap">
        <h2 id="stats-h">Live on-chain</h2>
        <span className="small muted">Read directly from the contracts on BNB Chain testnet</span>
      </div>
      <div className="stat-grid">
        {stats.map((s) => (
          <div key={s.label} className="stat card-stat">
            <div className="stat-label">{s.label}</div>
            {loading ? <div className="skel" style={{ height: 28, marginTop: 6 }} /> : <div className="stat-value">{s.value}</div>}
          </div>
        ))}
      </div>
    </section>
  );
}

const STEPS = [
  {
    n: "1",
    title: "Verify with vLEI",
    body: "Present your organisation's vLEI credential. The verifier checks the GLEIF trust chain and both signatures, and you register the attestation on-chain.",
  },
  {
    n: "2",
    title: "Invest in gated offerings",
    body: "Contribute to tokenized asset offerings that only accept verified legal entities, with a contribution cap per entity.",
  },
  {
    n: "3",
    title: "Earn yield only while verified",
    body: "Stake the token in the offering's vault to earn trading-tax yield in USDT. If your vLEI is revoked, rewards stop.",
  },
];

const TRUST = [
  {
    title: "GLEIF vLEI chain checks",
    body: "Every credential is checked back to a pinned root: GLEIF → qualified issuer → legal entity → role, including holder signatures and revocation status.",
  },
  {
    title: "Revocation enforced on-chain",
    body: "Offerings and yield vaults read the registry on every action. A revoked wallet or entity cannot contribute, claim or earn, and can be evicted from vaults.",
  },
  {
    title: "Per-entity caps",
    body: "Limits are enforced per legal entity (LEI), not per wallet, so one organisation cannot exceed its allocation by splitting across wallets.",
  },
];

export default function Overview() {
  return (
    <div className="stack-xl">
      <section className="hero-landing">
        <div className="hero-copy">
          <span className="chip-bnb">on BNB Chain</span>
          <h1>Institutional access for tokenized assets on BNB Chain</h1>
          <p className="lead">
            vLEI-Gate admits only verified legal entities to tokenized asset offerings, using GLEIF vLEI credentials as
            cryptographic proof of who is behind each wallet.
          </p>
          <p className="tagline">Don&apos;t trust. Verify.</p>
          <div className="row wrap">
            <Link href="/verify" className="btn primary lg">
              Verify your organisation
            </Link>
            <Link href="/offerings" className="btn secondary lg">
              Browse offerings
            </Link>
          </div>
        </div>
        <div className="hero-visual" aria-hidden>
          <div className="hv-card">
            <div className="hv-row">
              <span className="hv-seal">✓</span>
              <div>
                <div className="hv-title">vLEI credential verified</div>
                <div className="hv-sub">Sample organisation · testnet</div>
              </div>
            </div>
            <div className="hv-chain">
              <span>GLEIF root</span>
              <span>→</span>
              <span>Qualified issuer</span>
              <span>→</span>
              <span>Legal entity</span>
              <span>→</span>
              <span>Role</span>
            </div>
            <div className="hv-foot">
              <span className="badge ok">Verified</span>
              <span className="badge">Cap per entity</span>
              <span className="badge info">Yield while verified</span>
            </div>
          </div>
        </div>
      </section>

      <section aria-labelledby="how-h" className="stack">
        <h2 id="how-h">How it works</h2>
        <ol className="how">
          {STEPS.map((s) => (
            <li key={s.n} className="card">
              <span className="how-n" aria-hidden>
                {s.n}
              </span>
              <h3>{s.title}</h3>
              <p className="small muted">{s.body}</p>
            </li>
          ))}
        </ol>
      </section>

      <Stats />

      <section aria-labelledby="trust-h" className="stack">
        <h2 id="trust-h">Built for compliance teams</h2>
        <div className="trust">
          {TRUST.map((t) => (
            <div key={t.title} className="card">
              <h3>{t.title}</h3>
              <p className="small muted">{t.body}</p>
            </div>
          ))}
        </div>
        <p className="small muted">
          Testnet prototype using sample vLEI credentials for fictional organisations. Contracts are not audited.
        </p>
      </section>
    </div>
  );
}
