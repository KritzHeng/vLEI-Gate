"use client";

import { useEffect, useState } from "react";
import { factoryAbi, priceFeedAbi } from "@/lib/abis";
import { ApiError, backend, type CmcQuote, type Evidence, type RiskResult } from "@/lib/backend";
import { publicClient } from "@/lib/clients";
import { ADDRESSES_CONFIGURED, PRICE_FEED_FACTORY_ADDRESS } from "@/lib/config";
import { explainError } from "@/lib/errors";
import { fmtTime, short } from "@/lib/format";
import { useSession } from "@/lib/session";
import { useCournotAssessment } from "./RiskGate";

type Atlas = {
  price: number;
  decimals: number;
  updatedAt: number;
  feed: string;
  description: string;
  stale: boolean;
};

export function RiskCard({ r }: { r: RiskResult }) {
  const pct = `${(r.probability * 100).toFixed(1)}%`;
  return (
    <div className={`risk ${r.highRisk ? "bad" : "ok"}`}>
      <div className="row between wrap">
        <div>
          <span className="badge ok">LIVE · Cournot Intelligence Oracle</span>{" "}
          {r.highRisk ? <span className="badge bad">RATE RISK ELEVATED</span> : <span className="badge ok">below threshold</span>}
        </div>
        <div className="prob">
          p = {r.probability.toFixed(2)}{" "}
          <span className="small muted">
            ({pct} · threshold {r.threshold})
          </span>
        </div>
      </div>
      <div className="small muted">Question sent to Cournot: “{r.question}”</div>
      <div>
        <b>Claim evaluated</b> (Cournot market {r.marketId || "—"}
        {r.matchingConfidence != null && <>, match {r.matchingConfidence.toFixed(2)}</>}
        ): {r.claim || <span className="muted">(none)</span>}
      </div>
      {r.claimDetail && <div className="small muted">Resolution rules: {r.claimDetail}</div>}
      <div className="small">
        <b>Evidence (Cournot basis):</b>
        <ul>
          {r.evidence.length === 0 && <li className="muted">none returned</li>}
          {r.evidence.map((ev: Evidence, i) =>
            typeof ev === "string" ? (
              <li key={i}>{ev}</li>
            ) : (
              <li key={i}>
                {ev.source ? <span className="badge">{String(ev.source)}</span> : null}{" "}
                {ev.url ? (
                  <a href={String(ev.url)} target="_blank" rel="noreferrer">
                    {String(ev.title || ev.url)}
                  </a>
                ) : (
                  String(ev.title ?? JSON.stringify(ev))
                )}
                {ev.time ? <span className="muted"> · {String(ev.time)}</span> : null}
              </li>
            ),
          )}
        </ul>
      </div>
      {r.appNote && (
        <div className="small">
          <span className="badge">Added by vLEI-Gate</span> {r.appNote}
        </div>
      )}
      <div className="small mono muted">
        asked {r.askedAt}
        {r.latencyMs ? ` · ${r.latencyMs} ms` : ""}
        {r.billing ? ` · ${r.billing}` : ""}
        {r.cached ? " · latest logged live call" : " · new live call"} · requestId: {r.requestId || "not returned by Cournot"}
        {r.logFile && <> · proof {r.logFile}</>}
      </div>
    </div>
  );
}

export default function IntelPanel() {
  const session = useSession();
  const { risk: r, err: latestErr } = useCournotAssessment();
  const [busy, setBusy] = useState(false);
  const [riskErr, setRiskErr] = useState<string | null>(null);
  const [log, setLog] = useState<RiskResult[] | null>(null);

  const [atlas, setAtlas] = useState<Atlas | null>(null);
  const [atlasErr, setAtlasErr] = useState<string | null>(null);
  const [cmc, setCmc] = useState<CmcQuote | null>(null);
  const [cmcErr, setCmcErr] = useState<string | null>(null);

  /** Spends one Cournot call (free quota or API key) and stores the fresh assessment. */
  const query = async () => {
    setBusy(true);
    setRiskErr(null);
    try {
      const res = await backend.cournotRisk(true, session.verified?.entity_name ?? "", session.verified?.lei ?? "");
      session.update({ risk: { ...res, refreshError: undefined } });
      if (res.refreshError) setRiskErr(res.refreshError);
    } catch (e) {
      setRiskErr((e as Error).message);
    } finally {
      setBusy(false);
    }
  };

  const loadPrices = async () => {
    setAtlasErr(null);
    setCmcErr(null);
    if (ADDRESSES_CONFIGURED) {
      try {
        const F = {
          address: PRICE_FEED_FACTORY_ADDRESS,
          abi: factoryAbi,
        } as const;
        const [feed, maxAge] = await Promise.all([
          publicClient.readContract({ ...F, functionName: "priceFeed" }),
          publicClient.readContract({ ...F, functionName: "maxPriceAge" }),
        ]);
        const [[, answer, , updatedAt], decimals] = await Promise.all([
          publicClient.readContract({
            address: feed,
            abi: priceFeedAbi,
            functionName: "latestRoundData",
          }),
          publicClient.readContract({
            address: feed,
            abi: priceFeedAbi,
            functionName: "decimals",
          }),
        ]);
        let description = "";
        try {
          description = await publicClient.readContract({
            address: feed,
            abi: priceFeedAbi,
            functionName: "description",
          });
        } catch {
          /* optional */
        }
        if (answer <= 0n || updatedAt === 0n) {
          setAtlas(null);
          setAtlasErr(
            `No price on feed ${short(feed, 4)} yet${description ? ` (${description})` : ""}: run scripts/push_atlas_price.py.`,
          );
          return;
        }
        const stale = Date.now() / 1000 - Number(updatedAt) > Number(maxAge);
        setAtlas({
          price: Number(answer) / 10 ** decimals,
          decimals,
          updatedAt: Number(updatedAt),
          feed,
          description,
          stale,
        });
      } catch (e) {
        setAtlasErr(explainError(e));
      }
    } else {
      setAtlasErr("Factory address not configured.");
    }
    try {
      setCmc(await backend.cmc("BNB"));
    } catch (e) {
      setCmc(null);
      setCmcErr(
        e instanceof ApiError && e.status === 503 ? `CMC unavailable (${e.message})` : `CMC unavailable: ${(e as Error).message}`,
      );
    }
  };

  useEffect(() => {
    loadPrices();
  }, []);

  const deviation = atlas && cmc ? ((atlas.price - cmc.price) / cmc.price) * 100 : null;
  const isMockFeed = atlas?.description.toUpperCase().includes("MOCK");
  const isSignedAtlas = !isMockFeed && /atlas/i.test(atlas?.description ?? "") && /signed/i.test(atlas?.description ?? "");

  return (
    <section className="card">
      <div className="row between wrap">
        <h2 className="h-card">Risk &amp; market intelligence</h2>
        <span className="badge ok">Live data</span>
      </div>
      <p className="small muted">
        Live data behind the offering: a rate-risk probability from the Cournot Intelligence Oracle (it decides whether investors
        must acknowledge a risk notice before contributing) and the Atlas vs CoinMarketCap BNB/USD cross-check (it pauses BNB
        contributions when the sources disagree).
      </p>

      <h3>Rate risk (Cournot Intelligence Oracle)</h3>
      {!r && !riskErr && <div className="small muted">{latestErr ? "No live Cournot assessment logged yet." : "Loading…"}</div>}
      {riskErr && <div className="status bad">{riskErr}</div>}
      {r && <RiskCard r={r} />}
      <div className="row wrap small">
        <button className="secondary" onClick={query} disabled={busy}>
          {busy ? "Calling Cournot…" : "Run a new live Cournot call"}
        </button>
        <span className="muted">
          Uses one Cournot call (free quota is 3 per IP); the page otherwise shows the latest logged live result.
        </span>
      </div>
      <div className="small">
        <button
          className="link"
          onClick={() =>
            backend
              .cournotLog()
              .then(setLog)
              .catch((e) => setRiskErr((e as Error).message))
          }
        >
          show live execution log
        </button>
        {log && (
          <div className="table-scroll">
            <table className="table small">
              <thead>
                <tr>
                  <th>asked (UTC)</th>
                  <th>claim</th>
                  <th>p</th>
                  <th>billing</th>
                  <th>proof</th>
                </tr>
              </thead>
              <tbody>
                {log.length === 0 && (
                  <tr>
                    <td colSpan={5} className="muted">
                      no live Cournot calls logged yet
                    </td>
                  </tr>
                )}
                {log.map((l) => (
                  <tr key={l.logFile ?? l.askedAt}>
                    <td>{l.askedAt}</td>
                    <td>{l.claim}</td>
                    <td>{l.probability.toFixed(2)}</td>
                    <td>{l.billing ?? "—"}</td>
                    <td className="mono">{l.logFile?.split("/").pop()}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>

      <h3>BNB / USD price check</h3>
      <div className="prices">
        <div className="price">
          <div className="small muted">
            {isSignedAtlas ? "Atlas (signed, on-chain)" : "Atlas (on-chain, factory.priceFeed)"}{" "}
            {isMockFeed && <span className="badge mock">MOCK FEED</span>}{" "}
            {atlas?.stale && <span className="badge bad">STALE: contribute reverts StalePrice</span>}
          </div>
          {atlas ? (
            <>
              <div className="big">
                $
                {atlas.price.toLocaleString(undefined, {
                  maximumFractionDigits: 4,
                })}
              </div>
              <div className="small muted">
                updated {fmtTime(atlas.updatedAt)} · feed <span className="mono">{short(atlas.feed, 4)}</span>
                {atlas.description && <> · {atlas.description}</>}
              </div>
            </>
          ) : (
            <div className="muted">{atlasErr ?? "…"}</div>
          )}
        </div>
        <div className="price">
          <div className="small muted">CoinMarketCap (/v1/cryptocurrency/quotes/latest)</div>
          {cmc ? (
            <>
              <div className="big">
                $
                {cmc.price.toLocaleString(undefined, {
                  maximumFractionDigits: 4,
                })}
              </div>
              <div className="small muted">
                updated {cmc.lastUpdated ?? "—"} {cmc.cached && "· cached"}
              </div>
            </>
          ) : (
            <div className="muted">{cmcErr ?? "…"}</div>
          )}
        </div>
        <div className="price">
          <div className="small muted">Deviation (Atlas vs CMC)</div>
          <div className={`big ${deviation !== null && Math.abs(deviation) > 2 ? "text-bad" : ""}`}>
            {deviation === null ? "—" : `${deviation >= 0 ? "+" : ""}${deviation.toFixed(2)}%`}
          </div>
        </div>
      </div>
      <button className="link" onClick={loadPrices}>
        refresh prices
      </button>
    </section>
  );
}
