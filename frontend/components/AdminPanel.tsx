"use client";

import { useEffect, useState } from "react";
import { isAddress, isHex, type Address, type Hex } from "viem";
import { registryAbi, vaultV2Abi } from "@/lib/abis";
import { publicClient } from "@/lib/clients";
import { ADDRESSES_CONFIGURED, REGISTRY_ADDRESS } from "@/lib/config";
import { explainError } from "@/lib/errors";
import { fmtAmount, leiToHash, short } from "@/lib/format";
import { loadVaultsFor } from "@/lib/launches";
import { useSession } from "@/lib/session";
import { useTx } from "@/lib/tx";
import { useWallet } from "@/lib/wallet";
import { Flag } from "./RegistryStatus";
import RegistryStatus from "./RegistryStatus";
import TxStatus from "./TxStatus";

const ADMIN_ROLE = "0x0000000000000000000000000000000000000000000000000000000000000000" as Hex;

export { leiToHash };

type VaultRow = Awaited<ReturnType<typeof loadVaultsFor>>[number];

/** Lists the wallet's stake in every gated vault (vault-v2 factories) and offers evict. */
function EvictShortcut({ wallet }: { wallet: string }) {
  const w = useWallet();
  const tx = useTx();
  const [rows, setRows] = useState<VaultRow[] | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const valid = isAddress(wallet);
  const load = () => {
    if (!valid) return;
    setLoading(true);
    setErr(null);
    loadVaultsFor(wallet as Address)
      .then(setRows)
      .catch((e) => setErr(explainError(e)))
      .finally(() => setLoading(false));
  };
  useEffect(() => {
    setRows(null);
  }, [wallet]);
  useEffect(() => {
    if (rows !== null) load();
  }, [w.refreshKey]); // reload after a tx (evict) confirms
  const staked = rows?.filter((r) => r.stakedOf > 0n) ?? [];
  return (
    <div>
      <div className="row wrap">
        <button className="secondary" disabled={!valid || loading} onClick={load}>
          {loading ? "Checking vaults…" : "Find this wallet's vault stakes"}
        </button>
        {rows && (
          <span className="small muted">
            {rows.length} vault(s) checked, staked in {staked.length}
          </span>
        )}
      </div>
      {err && <div className="status bad">{err}</div>}
      {staked.map((r) => (
        <div key={r.vault} className="row wrap small">
          <span>
            {r.symbol} vault <span className="mono">{short(r.vault, 4)}</span>: staked {fmtAmount(r.stakedOf, r.symbol)} ·{" "}
            {r.evictable ? <span className="badge bad">evictable</span> : <span className="badge">not evictable</span>}
          </span>
          <button
            className="danger"
            disabled={["simulating", "signing", "pending"].includes(tx.state.phase)}
            onClick={() => tx.run({ address: r.vault, abi: vaultV2Abi, functionName: "evict", args: [wallet as Address] })}
          >
            Evict from vault
          </button>
        </div>
      ))}
      <TxStatus state={tx.state} />
    </div>
  );
}

export default function AdminPanel() {
  const w = useWallet();
  const { verified } = useSession();
  const [isAdmin, setIsAdmin] = useState<boolean | null>(null);
  const [wallet, setWallet] = useState("");
  const [lei, setLei] = useState("");
  const [leiHash, setLeiHash] = useState("");
  const [reason, setReason] = useState("watcher: TEL revocation detected");
  const [entityRevoked, setEntityRevoked] = useState<boolean | null>(null);
  const revWallet = useTx();
  const revEntity = useTx();
  const reinstate = useTx();

  useEffect(() => {
    if (verified) {
      setWallet((x) => x || verified.wallet);
      setLei((x) => x || verified.lei);
      setLeiHash((x) => x || verified.lei_hash);
    }
  }, [verified]);

  useEffect(() => {
    if (!w.account || !ADDRESSES_CONFIGURED) return;
    publicClient
      .readContract({ address: REGISTRY_ADDRESS, abi: registryAbi, functionName: "hasRole", args: [ADMIN_ROLE, w.account] })
      .then(setIsAdmin)
      .catch(() => setIsAdmin(null));
  }, [w.account]);

  const validHash = isHex(leiHash) && leiHash.length === 66;

  useEffect(() => {
    if (!validHash || !ADDRESSES_CONFIGURED) {
      setEntityRevoked(null);
      return;
    }
    publicClient
      .readContract({ address: REGISTRY_ADDRESS, abi: registryAbi, functionName: "entityRevoked", args: [leiHash as Hex] })
      .then(setEntityRevoked)
      .catch(() => setEntityRevoked(null));
  }, [leiHash, validHash, w.refreshKey]);

  const busy = (s: { phase: string }) => ["simulating", "signing", "pending"].includes(s.phase);

  return (
    <div className="cols">
      <section className="card">
        <div className="row between wrap">
          <h2 className="h-card">Revocation controls</h2>
          <span className="small">
            Admin role: {isAdmin === null ? <span className="badge">unknown</span> : <Flag ok={isAdmin} yes="granted" no="not granted" />}
          </span>
        </div>
        <p className="small muted">
          Acts on a revocation detected in the vLEI Transaction Event Log (TEL). Transactions are sent from the connected wallet,
          which must hold DEFAULT_ADMIN_ROLE on the registry (the verifier key cannot revoke). Typical flow: revoke the wallet or
          entity → evict its vault stakes → the holder sees &ldquo;Rewards suspended&rdquo; in Portfolio → it re-verifies.
        </p>
        <label>
          Reason
          <input value={reason} onChange={(e) => setReason(e.target.value)} />
        </label>

        <h3>Revoke a wallet</h3>
        <div className="row wrap">
          <input
            className="mono"
            style={{ flex: 1 }}
            placeholder="0x wallet"
            aria-label="Wallet address"
            value={wallet}
            onChange={(e) => setWallet(e.target.value.trim())}
          />
          <button
            className="danger"
            disabled={!isAddress(wallet) || busy(revWallet.state)}
            onClick={() =>
              revWallet.run({ address: REGISTRY_ADDRESS, abi: registryAbi, functionName: "revokeWallet", args: [wallet as Address, reason] })
            }
          >
            Revoke wallet
          </button>
        </div>
        <TxStatus state={revWallet.state} />

        <h3>Revoke / reinstate an entity</h3>
        <div className="row wrap">
          <input className="mono" style={{ flex: 1 }} placeholder="LEI" aria-label="LEI" value={lei} onChange={(e) => setLei(e.target.value)} />
          <button className="secondary" disabled={!lei.trim()} onClick={() => setLeiHash(leiToHash(lei))}>
            Compute leiHash
          </button>
        </div>
        <input className="mono" placeholder="0x leiHash (bytes32)" aria-label="leiHash" value={leiHash} onChange={(e) => setLeiHash(e.target.value.trim())} />
        <div className="small">Entity status: {entityRevoked === null ? "—" : <Flag ok={!entityRevoked} yes="active" no="REVOKED" />}</div>
        <div className="row wrap">
          <button
            className="danger"
            disabled={!validHash || busy(revEntity.state)}
            onClick={() =>
              revEntity.run({ address: REGISTRY_ADDRESS, abi: registryAbi, functionName: "revokeEntity", args: [leiHash as Hex, reason] })
            }
          >
            Revoke entity
          </button>
          <button
            className="secondary"
            disabled={!validHash || busy(reinstate.state)}
            onClick={() =>
              reinstate.run({ address: REGISTRY_ADDRESS, abi: registryAbi, functionName: "reinstateEntity", args: [leiHash as Hex] })
            }
          >
            Reinstate entity
          </button>
        </div>
        <TxStatus state={revEntity.state} />
        <TxStatus state={reinstate.state} />

        <p className="small muted">
          Effect on launchers: a revoked contributor cannot contribute or claim (NotVerified) and may withdrawContribution before
          the launch; if a launcher&apos;s creator is revoked, anyone can call cancelIfCreatorRevoked and every contributor can refund.
          Tokens already claimed stay tradable on the DEX.
        </p>
        <p className="small">
          <b>Gated vaults:</b> revocation is enforced lazily. After <span className="mono">revokeWallet</span> /{" "}
          <span className="mono">revokeEntity</span>, call <span className="mono">evict(staker)</span> in each vault where the revoked
          wallet (or each wallet of the revoked entity) is staked, so its stake stops diluting the others and its unclaimed USDT is
          forfeited to the remaining stakers. Anyone may evict; the stake tokens go back to the wallet.
        </p>
        <h3>Evict from gated vaults</h3>
        <EvictShortcut wallet={wallet} />
      </section>
      <section className="card">
        <h2 className="h-card">Wallet lookup</h2>
        {isAddress(wallet) ? (
          <RegistryStatus wallet={wallet as Address} title="Target wallet status" />
        ) : (
          <div className="muted small">Enter a wallet to see its status.</div>
        )}
      </section>
    </div>
  );
}
