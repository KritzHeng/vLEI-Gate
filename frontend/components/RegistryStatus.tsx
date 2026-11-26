"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import type { Address, Hex } from "viem";
import { registryAbi } from "@/lib/abis";
import { publicClient } from "@/lib/clients";
import { ADDRESSES_CONFIGURED, REGISTRY_ADDRESS, ROLE_NAMES } from "@/lib/config";
import { explainError } from "@/lib/errors";
import { fmtDuration, fmtTime, short } from "@/lib/format";
import { useSession } from "@/lib/session";
import { useWallet } from "@/lib/wallet";

export type Status = {
  leiHash: Hex;
  role: number;
  expiresAt: bigint;
  registeredAt: bigint;
  verifier: Address;
  isActive: boolean;
  canLaunch: boolean;
  walletRevoked: boolean;
  entityRevoked: boolean;
  nonce: bigint;
};

export async function readStatus(wallet: Address): Promise<Status> {
  const c = { address: REGISTRY_ADDRESS, abi: registryAbi } as const;
  const [reg, isActive, canLaunch, walletRevoked, nonce] = await Promise.all([
    publicClient.readContract({ ...c, functionName: "getRegistration", args: [wallet] }),
    publicClient.readContract({ ...c, functionName: "isActive", args: [wallet] }),
    publicClient.readContract({ ...c, functionName: "canLaunch", args: [wallet] }),
    publicClient.readContract({ ...c, functionName: "walletRevoked", args: [wallet] }),
    publicClient.readContract({ ...c, functionName: "nonces", args: [wallet] }),
  ]);
  const entityRevoked = await publicClient.readContract({ ...c, functionName: "entityRevoked", args: [reg.leiHash] });
  return {
    leiHash: reg.leiHash,
    role: reg.role,
    expiresAt: reg.expiresAt,
    registeredAt: reg.registeredAt,
    verifier: reg.verifier,
    isActive,
    canLaunch,
    walletRevoked,
    entityRevoked,
    nonce,
  };
}

/** Reads (and re-reads after every confirmed tx) the registry status of a wallet. */
export function useRegistryStatus(target: Address | null | undefined) {
  const w = useWallet();
  const [s, setS] = useState<Status | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [tick, setTick] = useState(0);
  useEffect(() => {
    setS(null);
  }, [target]);
  useEffect(() => {
    if (!target || !ADDRESSES_CONFIGURED) return;
    let live = true;
    setErr(null);
    setLoading(true);
    readStatus(target)
      .then((r) => live && setS(r))
      .catch((e) => live && setErr(explainError(e)))
      .finally(() => live && setLoading(false));
    return () => {
      live = false;
    };
  }, [target, w.refreshKey, tick]);
  return { status: s, err, loading, refresh: () => setTick((t) => t + 1) };
}

export type IdentityKind = "verified" | "revoked" | "expired" | "none";
export type Identity = { kind: IdentityKind; role: string; secondsLeft: number; warn: boolean; reason: string };

/** Expiry warning threshold: less than 2 hours of registration left. */
const WARN_SECONDS = 2 * 3600;

export function identityOf(s: Status, nowSec = Date.now() / 1000): Identity {
  const role = ROLE_NAMES[s.role] ?? String(s.role);
  const secondsLeft = Number(s.expiresAt) - nowSec;
  if (s.walletRevoked || s.entityRevoked) {
    const reason = s.entityRevoked && s.walletRevoked ? "entity and wallet revoked" : s.entityRevoked ? "entity vLEI revoked" : "wallet revoked";
    return { kind: "revoked", role, secondsLeft, warn: false, reason };
  }
  if (s.isActive) return { kind: "verified", role, secondsLeft, warn: secondsLeft < WARN_SECONDS, reason: "" };
  if (s.role !== 0 && s.expiresAt > 0n && secondsLeft <= 0) return { kind: "expired", role, secondsLeft, warn: true, reason: "registration expired" };
  return { kind: "none", role, secondsLeft, warn: false, reason: "no active registration" };
}

export function Flag({ ok, yes = "yes", no = "no" }: { ok: boolean; yes?: string; no?: string }) {
  return <span className={`badge ${ok ? "ok" : "bad"}`}>{ok ? yes : no}</span>;
}

/** Entity name from the demo session, if the session's verified wallet is this one. */
function useEntityName(target: Address | null | undefined): string | null {
  const { verified } = useSession();
  if (!target || !verified) return null;
  return verified.wallet.toLowerCase() === target.toLowerCase() ? verified.entity_name : null;
}

/** Compact identity pill for the header: Verified · entity · role · expires in Xh / Revoked / Expired / Not verified. */
export function IdentityBadge() {
  const w = useWallet();
  const { status, loading } = useRegistryStatus(w.account);
  const entity = useEntityName(w.account);
  if (!w.account || !ADDRESSES_CONFIGURED) return null;
  if (!status) return <span className="idbadge muted">{loading ? "Checking vLEI…" : "vLEI status unavailable"}</span>;
  const id = identityOf(status);
  if (id.kind === "verified") {
    return (
      <span
        className={`idbadge ${id.warn ? "warn" : "ok"}`}
        title={`Active vLEI registration on-chain${entity ? ` · ${entity}` : ""} · ${id.role} · expires in ${fmtDuration(id.secondsLeft)}`}
      >
        <span className="iddot" aria-hidden />
        Verified
        {entity && <span className="id-extra"> · {entity}</span>}
        <span className="id-extra"> · {id.role}</span>
        <span className={`id-extra ${id.warn ? "idwarn" : ""}`}> · {id.warn ? `expires in ${fmtDuration(id.secondsLeft)}` : fmtDuration(id.secondsLeft) + " left"}</span>
        {id.warn && (
          <Link href="/verify" className="idlink">
            Renew
          </Link>
        )}
      </span>
    );
  }
  const label = id.kind === "revoked" ? "Revoked" : id.kind === "expired" ? "Expired" : "Not verified";
  const tone = id.kind === "revoked" ? "bad" : id.kind === "expired" ? "warn" : "none";
  return (
    <span className={`idbadge ${tone}`} title={id.reason}>
      <span className="iddot" aria-hidden />
      {label}
      <Link href="/verify" className="idlink">
        {id.kind === "none" ? "Verify" : "Re-verify"}
      </Link>
    </span>
  );
}

/** On-chain registry status of a wallet (defaults to the connected one): one clear summary + collapsible raw fields. */
export default function RegistryStatus({ wallet, title = "On-chain registry status" }: { wallet?: Address | null; title?: string }) {
  const w = useWallet();
  const target = wallet ?? w.account;
  const { status: s, err, loading, refresh } = useRegistryStatus(target);
  const entity = useEntityName(target);

  if (!target) return <div className="muted small">Connect a wallet to see its registry status.</div>;
  const id = s ? identityOf(s) : null;
  const tone = !id ? "" : id.kind === "verified" ? (id.warn ? "warn" : "green") : id.kind === "expired" ? "warn" : id.kind === "revoked" ? "red" : "";

  return (
    <div className={`regstatus ${tone}`}>
      <div className="row between">
        <strong>{title}</strong>
        <button className="link small" onClick={refresh}>
          {loading ? "loading…" : "refresh"}
        </button>
      </div>
      <div className="small mono muted">{target}</div>
      {err && <div className="status bad">{err}</div>}
      {id && s && (
        <div className="regsummary" aria-live="polite">
          {id.kind === "verified" && (
            <>
              <span className="badge ok">Verified</span> {entity && <b>{entity}</b>} · role {id.role}
              {s.canLaunch && <span className="badge ok">can launch</span>} ·{" "}
              <span className={id.warn ? "text-warn" : "muted"}>expires in {fmtDuration(id.secondsLeft)}</span>
            </>
          )}
          {id.kind === "revoked" && (
            <>
              <span className="badge bad">Revoked</span> {id.reason}. Contributions, claims and vault rewards are blocked until a new
              verification is registered.
            </>
          )}
          {id.kind === "expired" && (
            <>
              <span className="badge warn">Expired</span> The registration expired {fmtTime(s.expiresAt)}. Verify again to renew it.
            </>
          )}
          {id.kind === "none" && (
            <>
              <span className="badge">Not verified</span> This wallet has no vLEI registration yet.
            </>
          )}
        </div>
      )}
      {s && (
        <details className="tech">
          <summary>Technical details</summary>
          <table className="kv">
            <tbody>
              <tr>
                <td>isActive</td>
                <td>
                  <Flag ok={s.isActive} yes="ACTIVE" no="NOT ACTIVE" />
                </td>
              </tr>
              <tr>
                <td>canLaunch</td>
                <td>
                  <Flag ok={s.canLaunch} />
                </td>
              </tr>
              <tr>
                <td>role</td>
                <td>
                  {ROLE_NAMES[s.role] ?? s.role} ({s.role})
                </td>
              </tr>
              <tr>
                <td>leiHash</td>
                <td className="mono">{s.role ? short(s.leiHash, 8) : "—"}</td>
              </tr>
              <tr>
                <td>expiresAt</td>
                <td>{fmtTime(s.expiresAt)}</td>
              </tr>
              <tr>
                <td>registeredAt</td>
                <td>{fmtTime(s.registeredAt)}</td>
              </tr>
              <tr>
                <td>verifier</td>
                <td className="mono">{s.role ? short(s.verifier, 4) : "—"}</td>
              </tr>
              <tr>
                <td>walletRevoked / entityRevoked</td>
                <td>
                  {s.walletRevoked ? <span className="badge bad">wallet revoked</span> : <span className="badge">wallet ok</span>}{" "}
                  {s.entityRevoked ? <span className="badge bad">entity revoked</span> : <span className="badge">entity ok</span>}
                </td>
              </tr>
              <tr>
                <td>nonce</td>
                <td>{s.nonce.toString()}</td>
              </tr>
            </tbody>
          </table>
        </details>
      )}
    </div>
  );
}
