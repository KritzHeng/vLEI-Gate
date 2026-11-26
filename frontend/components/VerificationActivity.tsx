"use client";

import { useEffect, useState } from "react";
import type { Hash, Hex } from "viem";
import { registryAbi } from "@/lib/abis";
import { backend, type Persona } from "@/lib/backend";
import { publicClient } from "@/lib/clients";
import { ADDRESSES_CONFIGURED, REGISTRY_ADDRESS, ROLE_NAMES, txUrl } from "@/lib/config";
import { leiToHash, short } from "@/lib/format";
import { useWallet } from "@/lib/wallet";

type Row = { kind: string; tone: "ok" | "bad" | "info"; subject: string; detail: string; block: bigint; tx: Hash | null; key: string };

/** Bounded look-back windows (blocks), largest first; public RPC nodes cap eth_getLogs ranges. */
const RANGES = [20_000n, 5_000n];
const LIMIT = 25;

/** Read-only feed of recent registry events (Registered / WalletRevoked / EntityRevoked / EntityReinstated). */
export default function VerificationActivity() {
  const w = useWallet();
  const [rows, setRows] = useState<Row[] | null>(null);
  const [span, setSpan] = useState<bigint | null>(null);
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    if (!ADDRESSES_CONFIGURED) {
      setFailed(true);
      return;
    }
    let live = true;
    (async () => {
      const personas = await backend.personas().catch(() => [] as Persona[]);
      const entityOf = new Map(personas.map((p) => [leiToHash(p.lei).toLowerCase(), p.entity]));
      const ent = (h: Hex) => entityOf.get(h.toLowerCase()) ?? `entity ${short(h, 4)}`;
      const latest = await publicClient.getBlockNumber();
      for (const range of RANGES) {
        try {
          const fromBlock = latest > range ? latest - range : 0n;
          const logs = await publicClient.getContractEvents({ address: REGISTRY_ADDRESS, abi: registryAbi, fromBlock, toBlock: latest });
          const out: Row[] = [];
          for (const lg of logs) {
            const a = (lg as unknown as { args: Record<string, unknown> }).args ?? {};
            const base = { block: lg.blockNumber ?? 0n, tx: lg.transactionHash ?? null, key: `${lg.transactionHash}-${lg.logIndex}` };
            if (lg.eventName === "Registered")
              out.push({
                ...base,
                kind: "Registered",
                tone: "ok",
                subject: short(String(a.wallet), 4),
                detail: `${ent(a.leiHash as Hex)} · ${ROLE_NAMES[Number(a.role)] ?? String(a.role)}`,
              });
            else if (lg.eventName === "WalletRevoked")
              out.push({ ...base, kind: "Wallet revoked", tone: "bad", subject: short(String(a.wallet), 4), detail: String(a.reason ?? "") });
            else if (lg.eventName === "EntityRevoked")
              out.push({ ...base, kind: "Entity revoked", tone: "bad", subject: ent(a.leiHash as Hex), detail: String(a.reason ?? "") });
            else if (lg.eventName === "EntityReinstated")
              out.push({ ...base, kind: "Entity reinstated", tone: "info", subject: ent(a.leiHash as Hex), detail: "" });
          }
          out.sort((x, y) => (x.block === y.block ? 0 : x.block > y.block ? -1 : 1));
          if (!live) return;
          setRows(out.slice(0, LIMIT));
          setSpan(range);
          setFailed(false);
          return;
        } catch {
          /* try a smaller window */
        }
      }
      if (live) setFailed(true);
    })().catch(() => live && setFailed(true));
    return () => {
      live = false;
    };
  }, [w.refreshKey]);

  return (
    <section className="card" aria-labelledby="activity-h">
      <div className="row between wrap">
        <h2 id="activity-h" className="h-card">
          Verification activity
        </h2>
        {span && <span className="small muted">last {span.toLocaleString()} blocks</span>}
      </div>
      {failed ? (
        <div className="small muted">Activity feed unavailable from this RPC node. Revocation controls above still work.</div>
      ) : rows === null ? (
        <div className="stack-sm" aria-busy="true">
          <div className="skel" />
          <div className="skel" />
          <div className="skel" style={{ width: "70%" }} />
        </div>
      ) : rows.length === 0 ? (
        <div className="empty slim">
          <div className="empty-title">No registry events in this window</div>
          <div className="small muted">Registrations and revocations appear here as they happen.</div>
        </div>
      ) : (
        <ul className="activity">
          {rows.map((r) => {
            const url = r.tx ? txUrl(r.tx) : null;
            return (
              <li key={r.key}>
                <span className={`badge ${r.tone}`}>{r.kind}</span>
                <span className="activity-subject">{r.subject}</span>
                {r.detail && <span className="small muted activity-detail">{r.detail}</span>}
                <span className="small muted num activity-block">
                  {url ? (
                    <a href={url} target="_blank" rel="noreferrer">
                      #{r.block.toString()} ↗
                    </a>
                  ) : (
                    `#${r.block.toString()}`
                  )}
                </span>
              </li>
            );
          })}
        </ul>
      )}
    </section>
  );
}
