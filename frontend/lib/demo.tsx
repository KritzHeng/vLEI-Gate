"use client";

import { createContext, useCallback, useContext, useEffect, useState, type ReactNode } from "react";

/** Demo mode: reveals rejection personas, attacker mode, the test-USDT faucet, factory tables and raw addresses.
 *  Off = the clean product view. Persisted in localStorage when available (the app works without it). */
type DemoCtx = { demo: boolean; setDemo: (v: boolean) => void; toggle: () => void };

const KEY = "vlei-gate-demo-mode";
const Ctx = createContext<DemoCtx | null>(null);

export function DemoProvider({ children }: { children: ReactNode }) {
  const [demo, setDemoState] = useState(false);
  useEffect(() => {
    try {
      if (localStorage.getItem(KEY) === "1") setDemoState(true);
    } catch {
      /* storage unavailable: stay off */
    }
  }, []);
  const setDemo = useCallback((v: boolean) => {
    setDemoState(v);
    try {
      localStorage.setItem(KEY, v ? "1" : "0");
    } catch {
      /* ignore */
    }
  }, []);
  return <Ctx.Provider value={{ demo, setDemo, toggle: () => setDemo(!demo) }}>{children}</Ctx.Provider>;
}

export function useDemo(): DemoCtx {
  const c = useContext(Ctx);
  if (!c) throw new Error("useDemo outside DemoProvider");
  return c;
}
