"use client";

import { createContext, useContext, useEffect, useState, type ReactNode } from "react";
import type { RiskResult, VerifyResult } from "./backend";

/** Demo session shared between the KYB, intelligence, launch and admin views.
 *  Persisted in sessionStorage so a page reload keeps the verified entity. */
export type Session = {
  personaId: string | null;
  verified: Pick<VerifyResult, "entity_name" | "lei" | "lei_hash" | "role" | "role_name" | "person_name"> & {
    wallet: string;
  } | null;
  risk: RiskResult | null;
};

type SessionCtx = Session & { update: (p: Partial<Session>) => void };

const KEY = "vlei-gate-session";
const empty: Session = { personaId: null, verified: null, risk: null };
const Ctx = createContext<SessionCtx | null>(null);

export function SessionProvider({ children }: { children: ReactNode }) {
  const [s, setS] = useState<Session>(empty);
  useEffect(() => {
    try {
      const raw = sessionStorage.getItem(KEY);
      if (raw) setS({ ...empty, ...JSON.parse(raw) });
    } catch {
      /* ignore */
    }
  }, []);
  const update = (p: Partial<Session>) =>
    setS((prev) => {
      const next = { ...prev, ...p };
      try {
        sessionStorage.setItem(KEY, JSON.stringify(next));
      } catch {
        /* ignore */
      }
      return next;
    });
  return <Ctx.Provider value={{ ...s, update }}>{children}</Ctx.Provider>;
}

export function useSession(): SessionCtx {
  const c = useContext(Ctx);
  if (!c) throw new Error("useSession outside SessionProvider");
  return c;
}
