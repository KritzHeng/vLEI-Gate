"use client";

import { useEffect, useState } from "react";
import { backend, type Health } from "@/lib/backend";
import { CHAIN, REGISTRY_ADDRESS, addressUrl } from "@/lib/config";
import { useDemo } from "@/lib/demo";
import { short } from "@/lib/format";

export default function Footer() {
  const { demo, setDemo } = useDemo();
  const [health, setHealth] = useState<Health | null>(null);
  useEffect(() => {
    backend.health().then(setHealth).catch(() => setHealth(null));
  }, []);
  const regUrl = addressUrl(REGISTRY_ADDRESS);
  return (
    <footer className="site-footer">
      <div className="container footer-row">
        <div className="footer-honesty">
          <span className="chip-bnb">on BNB Chain</span>
          <span>
            {CHAIN.name} · sample vLEI credentials · not audited
          </span>
        </div>
        <label className="demo-toggle">
          <input type="checkbox" role="switch" checked={demo} onChange={(e) => setDemo(e.target.checked)} aria-checked={demo} />
          <span className="switch" aria-hidden />
          <span>Demo mode</span>
        </label>
      </div>
      <div className="container footer-meta small">
        <span>
          vLEI-Gate is a testnet prototype. It is not affiliated with or endorsed by GLEIF. Not investment advice.
        </span>
        {regUrl && (
          <a href={regUrl} target="_blank" rel="noreferrer">
            Registry contract ↗
          </a>
        )}
      </div>
      {demo && health && (
        <div className="container footer-meta small mono-soft">
          Verifier online · chain {health.chainId} · signer {short(health.verifierSigner, 4)} · pinned root {short(health.pinnedRootAid, 5)} ·
          nonce {health.nonceSource ?? "client"} · Cournot {health.cournotMode} · CMC {health.cmcConfigured ? "configured" : "not configured"}
        </div>
      )}
    </footer>
  );
}
