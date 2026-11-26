"use client";

import IntelPanel from "@/components/IntelPanel";
import KybPanel from "@/components/KybPanel";
import RegistryStatus from "@/components/RegistryStatus";

export default function VerifyPage() {
  return (
    <div className="stack-lg">
      <div className="page-head">
        <div>
          <div className="eyebrow">Step 1 · Know your business</div>
          <h1>Verify your organisation</h1>
          <p className="lead">
            Present a vLEI credential issued under the GLEIF trust chain. The verifier checks the full chain, both signatures and
            revocation status, then you register the resulting attestation on-chain.
          </p>
        </div>
      </div>
      <div className="detail-grid">
        <KybPanel />
        <aside className="stack">
          <section className="card">
            <RegistryStatus title="This wallet on-chain" />
          </section>
          <IntelPanel />
        </aside>
      </div>
    </div>
  );
}
