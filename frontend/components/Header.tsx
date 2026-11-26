"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useEffect, useState } from "react";
import { ADDRESSES_CONFIGURED, CHAIN, CHAIN_ID, REGISTRY_ADDRESS } from "@/lib/config";
import { backend, type Health } from "@/lib/backend";
import { useDemo } from "@/lib/demo";
import { short } from "@/lib/format";
import { useWallet } from "@/lib/wallet";
import { IdentityBadge } from "./RegistryStatus";

export const NAV = [
  { href: "/", label: "Overview" },
  { href: "/verify", label: "Verify" },
  { href: "/offerings", label: "Offerings" },
  { href: "/portfolio", label: "Portfolio" },
  { href: "/compliance", label: "Compliance" },
];

/** Simple wordmark: a shield with a check (no third-party marks). */
export function Logo() {
  return (
    <Link href="/" className="logo" aria-label="vLEI-Gate home">
      <svg width="26" height="26" viewBox="0 0 32 32" aria-hidden focusable="false">
        <path d="M16 2.5 4.5 6.8v8.6c0 7.1 4.8 12.4 11.5 14.1 6.7-1.7 11.5-7 11.5-14.1V6.8L16 2.5Z" fill="#1D4ED8" />
        <path d="M16 2.5 4.5 6.8v8.6c0 7.1 4.8 12.4 11.5 14.1V2.5Z" fill="#2563EB" />
        <path d="m10.5 16.2 3.8 3.8 7.4-7.6" fill="none" stroke="#fff" strokeWidth="2.6" strokeLinecap="round" strokeLinejoin="round" />
      </svg>
      <span className="logo-text">
        vLEI<span className="logo-dash">-</span>Gate
      </span>
    </Link>
  );
}

export default function Header() {
  const path = usePathname();
  const w = useWallet();
  const { demo, setDemo } = useDemo();
  const [health, setHealth] = useState<Health | null>(null);
  const [healthErr, setHealthErr] = useState<string | null>(null);

  useEffect(() => {
    backend.health().then(setHealth).catch((e) => setHealthErr((e as Error).message));
  }, []);

  const backendMismatch: string[] = [];
  if (health) {
    if (health.chainId !== CHAIN_ID) backendMismatch.push(`backend CHAIN_ID=${health.chainId}, frontend=${CHAIN_ID}`);
    if (health.registry && health.registry.toLowerCase() !== REGISTRY_ADDRESS.toLowerCase())
      backendMismatch.push(`backend registry ${short(health.registry)} ≠ frontend ${short(REGISTRY_ADDRESS)}`);
  }
  const isActive = (href: string) => (href === "/" ? path === "/" : path === href || path.startsWith(href + "/"));

  return (
    <>
      <header className="site-header">
        <div className="container header-row">
          <Logo />
          <nav className="nav" aria-label="Main">
            {NAV.map((n) => (
              <Link key={n.href} href={n.href} className={isActive(n.href) ? "active" : ""} aria-current={isActive(n.href) ? "page" : undefined}>
                {n.label}
              </Link>
            ))}
          </nav>
          <div className="header-right">
            {demo && (
              <button type="button" className="pill-demo" onClick={() => setDemo(false)} title="Demo mode is on. Click to turn it off.">
                Demo
              </button>
            )}
            <IdentityBadge />
            {w.account ? (
              <span className="wallet-pill mono" title={w.account}>
                <span className={`chain-dot ${w.wrongChain ? "bad" : "ok"}`} aria-hidden />
                {short(w.account, 4)}
              </span>
            ) : (
              <button className="primary btn-sm" onClick={w.connect}>
                {w.hasProvider ? "Connect wallet" : "No wallet found"}
              </button>
            )}
          </div>
        </div>
      </header>
      <div className="container banners" aria-live="polite">
        {w.wrongChain && (
          <div className="banner warn row wrap between">
            <span>
              Your wallet is on chain {w.chainId}. vLEI-Gate runs on {CHAIN.name} ({CHAIN_ID}).
            </span>
            <button className="primary btn-sm" onClick={w.switchChain}>
              Switch network
            </button>
          </div>
        )}
        {w.error && <div className="banner bad">{w.error}</div>}
        {!ADDRESSES_CONFIGURED && (
          <div className="banner warn">
            Contract addresses are not configured (NEXT_PUBLIC_REGISTRY_ADDRESS / NEXT_PUBLIC_FACTORY_ADDRESS). Copy
            .env.local.example to .env.local and fill them from contracts/deployments/{CHAIN_ID}.json.
          </div>
        )}
        {healthErr && <div className="banner bad">Verification service unavailable: {healthErr}</div>}
        {health && !health.demoAgent && (
          <div className="banner warn">
            The sample credential holder agent is disabled on the backend, so credentials cannot be presented. Restart the backend
            with ENABLE_DEMO_AGENT=true.
          </div>
        )}
        {backendMismatch.length > 0 && (
          <div className="banner bad">
            Verifier and app configuration differ ({backendMismatch.join("; ")}). On-chain registration would fail with
            InvalidSigner or a domain mismatch.
          </div>
        )}
      </div>
    </>
  );
}
