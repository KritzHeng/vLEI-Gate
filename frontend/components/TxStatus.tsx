"use client";

import { txUrl } from "@/lib/config";
import { short } from "@/lib/format";
import type { TxState } from "@/lib/tx";

const ICON: Record<string, string> = { success: "✓", error: "✗", reverted: "✗" };

/** Inline transaction status (simulate → sign → pending → result), announced to screen readers. */
export default function TxStatus({ state, success }: { state: TxState; success?: string }) {
  const live = state.phase === "error" || state.phase === "reverted" ? "assertive" : "polite";
  if (state.phase === "idle") return <div aria-live="polite" className="sr-only" />;
  const cls =
    state.phase === "success" ? "ok" : state.phase === "error" || state.phase === "reverted" ? "bad" : "info";
  const url = state.hash ? txUrl(state.hash) : null;
  const pending = state.phase === "simulating" || state.phase === "signing" || state.phase === "pending";
  return (
    <div className={`status ${cls}`} role={cls === "bad" ? "alert" : "status"} aria-live={live}>
      <strong aria-hidden>{pending ? <span className="spinner" /> : ICON[state.phase] ?? "…"} </strong>
      {state.phase === "success" && success ? success : state.message}
      {state.hash && (
        <div className="small mono">
          tx:{" "}
          {url ? (
            <a href={url} target="_blank" rel="noreferrer">
              {short(state.hash, 8)} ↗
            </a>
          ) : (
            short(state.hash, 8)
          )}
        </div>
      )}
    </div>
  );
}
