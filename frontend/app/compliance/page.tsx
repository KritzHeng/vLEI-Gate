"use client";

import AdminPanel from "@/components/AdminPanel";
import VerificationActivity from "@/components/VerificationActivity";

export default function CompliancePage() {
  return (
    <div className="stack-lg">
      <div className="page-head">
        <div>
          <h1>Compliance</h1>
          <p className="lead">
            Revoke wallets or legal entities when a vLEI is revoked, reinstate entities, and evict revoked stakers from yield vaults.
            Revocation is enforced on-chain by every offering and vault.
          </p>
        </div>
      </div>
      <AdminPanel />
      <VerificationActivity />
    </div>
  );
}
