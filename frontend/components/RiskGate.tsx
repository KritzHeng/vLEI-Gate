"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { backend, type RiskResult } from "@/lib/backend";
import { useSession } from "@/lib/session";

/** A live Cournot assessment (rejects pre-live/mock session values and malformed objects). */
export const isLiveRisk = (r: RiskResult | null | undefined): r is RiskResult =>
  !!r && r.source === "cournot" && !!r.question && typeof r.probability === "number" && Number.isFinite(r.probability);

/** Loads the latest logged live Cournot assessment into the session on mount (no quota spent). */
export function useCournotAssessment() {
  const session = useSession();
  const [err, setErr] = useState<string | null>(null);
  useEffect(() => {
    let live = true;
    backend
      .cournotLatest()
      .then((r) => {
        if (!live) return;
        setErr(null);
        session.update({ risk: r });
      })
      .catch((e) => live && setErr((e as Error).message));
    return () => {
      live = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
  return { risk: isLiveRisk(session.risk) ? session.risk : null, err };
}

const pct = (p: number) => `${(p * 100).toFixed(0)}%`;

/** Decision gate driven by Cournot's probability: at or above the threshold, investors must acknowledge rate risk. */
export default function RiskGate({ confirmed, onChange }: { confirmed: boolean; onChange: (v: boolean) => void }) {
  const { risk, err } = useCournotAssessment();
  if (!risk) {
    return (
      <div className="banner info small">
        {err ? "No live Cournot assessment available yet." : "Loading the Cournot rate-risk assessment…"}{" "}
        <Link href="/verify">See Risk &amp; market intelligence</Link>.
      </div>
    );
  }
  const asked = new Date(risk.askedAt).toLocaleString();
  if (!risk.highRisk) {
    return (
      <div className="banner ok small">
        Cournot rate risk: p = {risk.probability.toFixed(2)} ({pct(risk.probability)}) below the {risk.threshold} threshold for “
        {risk.claim}”. <span className="muted">Assessed {asked}.</span>
      </div>
    );
  }
  return (
    <div className="banner bad">
      <div>
        <b>Rate risk elevated (Cournot)</b>: p = {risk.probability.toFixed(2)} ≥ {risk.threshold} that “{risk.claim}”.{" "}
        <span className="small muted">Assessed {asked}.</span>
      </div>
      <div className="small">
        Higher Treasury yields lower the value of the Treasury holdings behind this offering.{" "}
        <span className="muted">(Explanation added by vLEI-Gate.)</span> <Link href="/verify">Claim and evidence</Link>
      </div>
      <label className="small">
        <input type="checkbox" checked={confirmed} onChange={(e) => onChange(e.target.checked)} /> I have reviewed this rate-risk
        assessment and want to proceed. (Required to contribute; enforced in this app, not on-chain.)
      </label>
    </div>
  );
}

export function needsConfirmation(risk: { highRisk: boolean } | null, confirmed: boolean): boolean {
  return !!risk?.highRisk && !confirmed;
}
