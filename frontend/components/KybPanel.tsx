"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { useDemo } from "@/lib/demo";
import type { Address, Hex } from "viem";
import { registryAbi } from "@/lib/abis";
import { backend, type Challenge, type Persona, type Presentation, type VerifyResult } from "@/lib/backend";
import { publicClient } from "@/lib/clients";
import { ADDRESSES_CONFIGURED, CHAIN_ID, REGISTRY_ADDRESS } from "@/lib/config";
import { explainError } from "@/lib/errors";
import { fmtTime, short } from "@/lib/format";
import { useSession } from "@/lib/session";
import { useTx } from "@/lib/tx";
import { useWallet } from "@/lib/wallet";
import TxStatus from "./TxStatus";

type Sigs = { holderAid: string; holderSig: string; signedAs: string; walletSig: string };

export default function KybPanel() {
  const w = useWallet();
  const session = useSession();
  const { demo } = useDemo();
  const reg = useTx();

  const [personas, setPersonas] = useState<Persona[]>([]);
  const [personaId, setPersonaId] = useState<string>("");
  const [pres, setPres] = useState<Presentation | null>(null);
  const [action, setAction] = useState<"launch" | "invest">("launch");
  const [attacker, setAttacker] = useState(false);
  const [signAs, setSignAs] = useState<string>("");
  const [challenge, setChallenge] = useState<Challenge | null>(null);
  const [sigs, setSigs] = useState<Sigs | null>(null);
  const [nonceUsed, setNonceUsed] = useState<bigint | null>(null);
  const [result, setResult] = useState<VerifyResult | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);

  const persona = personas.find((p) => p.id === personaId) || null;
  // Product view lists only the valid sample organisations; demo mode adds the rejection scenarios.
  const visible = demo ? personas : personas.filter((p) => p.scenario === "valid");

  useEffect(() => {
    backend
      .personas()
      .then((ps) => {
        setPersonas(ps);
        const valid = ps.filter((p) => p.scenario === "valid");
        const pool = valid.length ? valid : ps;
        if (ps.length && !personaId)
          setPersonaId(session.personaId && pool.some((p) => p.id === session.personaId) ? session.personaId : pool[0].id);
      })
      .catch((e) => setErr(`Could not load sample credentials: ${(e as Error).message}`));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Leaving demo mode: fall back to a valid organisation and switch attacker mode off.
  useEffect(() => {
    if (demo) return;
    setAttacker(false);
    if (persona && persona.scenario !== "valid") {
      const first = personas.find((p) => p.scenario === "valid");
      if (first) setPersonaId(first.id);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [demo]);

  // Any change upstream invalidates the downstream steps.
  const resetFrom = (step: "presentation" | "challenge" | "sign") => {
    if (step === "presentation") setPres(null);
    if (step !== "sign") setChallenge(null);
    setSigs(null);
    setResult(null);
    setNonceUsed(null);
    setErr(null);
    reg.reset();
  };

  useEffect(() => {
    resetFrom("presentation");
    if (persona) {
      setAction(persona.credentialType === "OOR" && persona.id === "alice" ? "launch" : "invest");
      const other = personas.find((p) => p.id !== persona.id);
      setSignAs(other?.id ?? "");
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [personaId]);

  useEffect(() => {
    resetFrom("challenge");
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [w.account]);

  const step = async (name: string, fn: () => Promise<void>) => {
    setBusy(name);
    setErr(null);
    try {
      await fn();
    } catch (e) {
      setErr(explainError(e));
    } finally {
      setBusy(null);
    }
  };

  const loadPresentation = () =>
    step("load", async () => {
      resetFrom("presentation");
      setPres(await backend.presentation(personaId));
      session.update({ personaId });
    });

  const requestChallenge = () =>
    step("challenge", async () => {
      if (!w.account) throw new Error("Connect a wallet first.");
      if (!pres) throw new Error("Load the presentation first.");
      resetFrom("challenge");
      setChallenge(await backend.challenge(w.account, pres.holder));
    });

  const signBoth = () =>
    step("sign", async () => {
      if (!challenge || !w.walletClient || !w.account) throw new Error("Request a challenge first.");
      const signer = attacker && demo ? signAs : personaId;
      if (!signer) throw new Error("Pick a persona to sign as.");
      const holder = await backend.agentSign(signer, challenge.message);
      const walletSig = await w.walletClient.signMessage({ account: w.account, message: challenge.message });
      setSigs({ holderAid: holder.aid, holderSig: holder.signature, signedAs: signer, walletSig });
      setResult(null);
    });

  const verify = () =>
    step("verify", async () => {
      if (!challenge || !sigs || !pres || !w.account) throw new Error("Sign the challenge first.");
      if (!ADDRESSES_CONFIGURED) throw new Error("Registry address not configured.");
      // Read the registry nonce BEFORE verifying: the attestation must carry the current nonce.
      // (If the backend has RPC_URL set it reads the nonce on-chain itself; ours is the fallback.)
      const nonce = await publicClient.readContract({
        address: REGISTRY_ADDRESS,
        abi: registryAbi,
        functionName: "nonces",
        args: [w.account],
      });
      setNonceUsed(nonce);
      const r = await backend.verify({
        challengeId: challenge.id,
        leafSaid: pres.leafSaid,
        credentials: pres.credentials,
        holderSignature: sigs.holderSig,
        walletSignature: sigs.walletSig,
        action,
        registryNonce: Number(nonce),
      });
      setResult(r);
      // The challenge is single-use on the backend, so force a new one for the next attempt.
      setChallenge(null);
      if (r.ok) {
        session.update({
          personaId,
          verified: {
            wallet: w.account,
            entity_name: r.entity_name,
            lei: r.lei,
            lei_hash: r.lei_hash,
            role: r.role,
            role_name: r.role_name,
            person_name: r.person_name,
          },
        });
      }
    });

  const register = async () => {
    const att = result?.attestation;
    if (!att) return;
    if (att.domain.chainId !== CHAIN_ID) {
      setErr(`Attestation is for chainId ${att.domain.chainId}, but this app is on ${CHAIN_ID}.`);
      return;
    }
    const m = att.message;
    await reg.run({
      address: REGISTRY_ADDRESS,
      abi: registryAbi,
      functionName: "register",
      args: [
        {
          wallet: m.wallet as Address,
          leiHash: m.leiHash as Hex,
          role: Number(m.role),
          nonce: BigInt(m.nonce),
          expiresAt: BigInt(m.expiresAt),
        },
        att.signature as Hex,
      ],
    });
  };

  // ---- stepper state -------------------------------------------------------------------------------------------
  const txBusy = reg.state.phase === "simulating" || reg.state.phase === "signing" || reg.state.phase === "pending";
  const registered = reg.state.phase === "success";
  const done = [!!pres, !!challenge || !!sigs || !!result, !!sigs, !!result?.ok, registered];
  // A rejected verification consumed the challenge: the next thing to do is request a new one.
  const current = result && !result.ok ? 1 : done.findIndex((d) => !d);
  const doneCount = done.filter(Boolean).length;
  const stepCls = (i: number) => (i === current ? "current" : done[i] ? "done" : "upcoming");
  const btnCls = (i: number) => (i === current ? "primary" : "secondary");

  const reasons = {
    load: !personaId ? "Choose a credential first." : null,
    challenge: !w.account ? "Connect your wallet first." : !pres ? "Load the credential presentation first (step 1)." : null,
    sign: !challenge
      ? result
        ? "Challenges are single-use: request a new one (step 2)."
        : "Request a challenge first (step 2)."
      : null,
    verify: !challenge
      ? result
        ? "The last challenge was used: request a new one (step 2)."
        : "Request a challenge first (step 2)."
      : !sigs
        ? "Sign the challenge first (step 3)."
        : null,
  };
  const hint = (r: string | null) => (r && busy === null ? <span className="hint">{r}</span> : null);

  const expiresAt = result?.attestation ? Number(result.attestation.message.expiresAt) : 0;

  return (
    <section className="card kyb" aria-labelledby="kyb-title">
      <div className="row between wrap">
        <div>
          <h2 id="kyb-title">Present your vLEI credential</h2>
          <p className="muted small">
            Prove that this wallet acts for a legal entity with a GLEIF vLEI credential, then record the proof on-chain so offerings
            and yield vaults can check it.
          </p>
        </div>
        <span className="small muted num">{doneCount}/5 complete</span>
      </div>

      <ol className="stepper" aria-label="Verification progress">
        {STEPS.map((st, i) => (
          <li key={st.short} className={stepCls(i)} aria-current={i === current ? "step" : undefined}>
            <span className="dot" aria-hidden>
              {done[i] && i !== current ? "✓" : i + 1}
            </span>
            <span className="lbl">{st.short}</span>
            <span className="sr-only"> ({stepCls(i)})</span>
          </li>
        ))}
      </ol>

      {/* Step 1: credential source + presentation */}
      <div className={`step ${stepCls(0)}`}>
        <StepTitle i={0} />
        <div className="row wrap">
          <label className="grow">
            Organisation credential (sample, testnet)
            <select value={personaId} onChange={(e) => setPersonaId(e.target.value)}>
              {visible.map((p) => (
                <option key={p.id} value={p.id}>
                  {p.entity} — {p.personLegalName}, {p.role} ({p.credentialType})
                  {p.scenario !== "valid" ? ` · expected rejection: ${p.scenario}` : ""}
                </option>
              ))}
            </select>
          </label>
          <button className={btnCls(0)} onClick={loadPresentation} disabled={!personaId || busy !== null}>
            {busy === "load" ? "Loading…" : pres ? "Reload credential" : "Load credential"}
          </button>
          {hint(reasons.load)}
        </div>
        {persona && (
          <div className="small muted">
            {persona.description}
            {persona.scenario !== "valid" && <span className="badge mock"> DEMO · {persona.scenario}</span>}
          </div>
        )}
        {pres && <div className="small text-ok">✓ Credential chain loaded ({pres.credentials.length} credentials)</div>}
      </div>

      {/* Step 2: challenge */}
      <div className={`step ${stepCls(1)}`}>
        <StepTitle i={1} />
        <div className="row wrap">
          <label>
            What will this wallet do?
            <select value={action} onChange={(e) => setAction(e.target.value as "launch" | "invest")}>
              <option value="invest">Invest (contribute, stake, claim yield)</option>
              <option value="launch">Issue an offering (create a launcher)</option>
            </select>
          </label>
          {!w.account ? (
            <button className="primary" onClick={w.connect}>
              Connect wallet
            </button>
          ) : (
            <button className={btnCls(1)} onClick={requestChallenge} disabled={!pres || busy !== null}>
              {busy === "challenge" ? "Requesting…" : challenge ? "Request a new challenge" : "Request challenge"}
            </button>
          )}
          {w.account && hint(reasons.challenge)}
        </div>
        {challenge && <div className="small text-ok">✓ Challenge ready · expires {fmtTime(challenge.expiresAt)} · single use</div>}
      </div>

      {/* Step 3: dual signature */}
      <div className={`step ${stepCls(2)}`}>
        <StepTitle i={2} />
        <div className="row wrap">
          <button className={btnCls(2)} onClick={signBoth} disabled={!challenge || busy !== null}>
            {busy === "sign" ? "Signing…" : "Sign with credential + wallet"}
          </button>
          {hint(reasons.sign)}
        </div>
        {sigs && <div className="small text-ok">✓ Signed by the credential holder and by your wallet</div>}
        {demo && (
        <details className="tech">
          <summary>
            Attacker mode <span className="badge mock">DEMO</span>
          </summary>
          <div className={`attacker ${attacker ? "on" : ""}`}>
            <label>
              <input
                type="checkbox"
                checked={attacker}
                onChange={(e) => {
                  setAttacker(e.target.checked);
                  setSigs(null);
                  setResult(null);
                }}
              />{" "}
              Present <b>{personaId}</b>&apos;s credentials but sign the holder challenge as someone else
            </label>
            {attacker && (
              <label>
                Sign as
                <select value={signAs} onChange={(e) => setSignAs(e.target.value)}>
                  {personas
                    .filter((p) => p.id !== personaId)
                    .map((p) => (
                      <option key={p.id} value={p.id}>
                        {p.id}
                      </option>
                    ))}
                </select>
              </label>
            )}
          </div>
        </details>
        )}
      </div>

      {/* Step 4: verify */}
      <div className={`step ${stepCls(3)}`}>
        <StepTitle i={3} />
        <div className="row wrap">
          <button className={btnCls(3)} onClick={verify} disabled={!sigs || !challenge || busy !== null}>
            {busy === "verify" ? "Verifying…" : "Verify credential"}
          </button>
          {hint(reasons.verify)}
        </div>
        <div aria-live="polite" className="verdict-wrap">
          {result && result.ok && (
            <div className="cert">
              <div className="cert-head">
                <span className="cert-seal" aria-hidden>
                  ✓
                </span>
                <div>
                  <div className="cert-title">vLEI credential verified</div>
                  <div className="small muted">Attestation issued by the vLEI-Gate verifier · ready to register on-chain</div>
                </div>
              </div>
              <dl className="cert-grid">
                <div>
                  <dt>Legal entity</dt>
                  <dd>{result.entity_name || "—"}</dd>
                </div>
                <div>
                  <dt>LEI</dt>
                  <dd className="mono">{result.lei || "—"}</dd>
                </div>
                <div>
                  <dt>Role</dt>
                  <dd>
                    {result.official_role || result.credential_type}
                    {result.role_name && <span className="badge info">{result.role_name}</span>}
                  </dd>
                </div>
                <div>
                  <dt>Representative</dt>
                  <dd>{result.person_name || "—"}</dd>
                </div>
                <div>
                  <dt>Attestation expires</dt>
                  <dd>{expiresAt ? fmtTime(expiresAt) : "—"}</dd>
                </div>
                <div>
                  <dt>Wallet</dt>
                  <dd className="mono">{w.account ? short(w.account, 6) : "—"}</dd>
                </div>
              </dl>
              <details className="tech">
                <summary>{result.checks.filter((c) => c.ok === true).length} verification checks passed</summary>
                <Checks result={result} />
              </details>
            </div>
          )}
          {result && !result.ok && (
            <div className="verdict bad">
              <div className="verdict-head">✗ Credential rejected{result.entity_name && <span className="small"> · {result.entity_name}</span>}</div>
              <Checks result={result} />
              {result.error && <div className="small">Reason: {result.error}</div>}
              <div className="small">Fix the cause above, then request a new challenge (step 2) and try again.</div>
            </div>
          )}
        </div>
      </div>

      {/* Step 5: register */}
      <div className={`step ${stepCls(4)}`}>
        <StepTitle i={4} />
        <div className="row wrap">
          <button className={btnCls(4)} onClick={register} disabled={!result?.ok || !result.attestation || txBusy}>
            {txBusy ? "Registering…" : registered ? "Registered ✓" : "Register on-chain"}
          </button>
          {!(result?.ok && result.attestation) && <span className="hint">Available after a successful verification (step 4).</span>}
        </div>
        <TxStatus state={reg.state} success="Registered on-chain. This wallet is now verified." />
        {registered && (
          <div className="banner ok row wrap between">
            <span>
              <b>You&apos;re verified.</b> Your organisation can now invest in gated offerings and earn vault yield.
            </span>
            <span className="row wrap">
              <Link className="btn primary btn-sm" href="/offerings">
                Browse offerings
              </Link>
              <Link className="btn secondary btn-sm" href="/portfolio">
                Portfolio
              </Link>
            </span>
          </div>
        )}
      </div>

      {err && (
        <div className="status bad" role="alert">
          {err}
        </div>
      )}

      <details className="tech" open={demo || undefined}>
        <summary>Technical details</summary>
        <div className="small stack-sm">
          {persona && (
            <div>
              LEI <span className="mono">{persona.lei}</span>
            </div>
          )}
          {pres && (
            <div>
              Leaf SAID <span className="mono">{short(pres.leafSaid, 8)}</span> · holder AID <span className="mono">{short(pres.holder, 8)}</span>{" "}
              · {pres.credentials.length} credentials in bundle
            </div>
          )}
          {challenge && <pre className="msg">{challenge.message}</pre>}
          {sigs && (
            <div className="mono sigs">
              <div>
                holder sig ({sigs.signedAs}, AID {short(sigs.holderAid, 6)}): {short(sigs.holderSig, 10)}
              </div>
              <div>wallet sig (personal_sign): {short(sigs.walletSig, 10)}</div>
            </div>
          )}
          {nonceUsed !== null && <div>registryNonce sent: {nonceUsed.toString()}</div>}
          {result && result.lei && (
            <div>
              LEI <span className="mono">{result.lei}</span> · leiHash <span className="mono">{short(result.lei_hash, 8)}</span>
            </div>
          )}
          {result && result.chain.length > 0 && <div>Chain: {result.chain.map((c) => `${c.type} ${short(c.said, 4)}`).join(" → ")}</div>}
          {result?.attestation && (
            <div className="mono">
              Attestation(wallet {short(result.attestation.message.wallet, 4)}, leiHash {short(result.attestation.message.leiHash, 6)}, role{" "}
              {result.attestation.message.role}, nonce {String(result.attestation.message.nonce)}, expiresAt{" "}
              {fmtTime(Number(result.attestation.message.expiresAt))})
              {result.attestation.nonceSource && <span className="muted"> · nonce source: {result.attestation.nonceSource}</span>} ·
              registry.register(attestation, signature)
            </div>
          )}
          {!persona && !pres && !challenge && <div className="muted">Nothing yet.</div>}
        </div>
      </details>
    </section>
  );
}

const STEPS = [
  {
    short: "Credential",
    title: "Choose your organisation credential",
    why: "Loads the chain GLEIF → QVI → Legal Entity → role credential that says who this wallet acts for.",
  },
  {
    short: "Challenge",
    title: "Get a one-time challenge",
    why: "A fresh, single-use message ties this proof to your wallet and stops anyone replaying an old one.",
  },
  {
    short: "Sign",
    title: "Sign it twice",
    why: "The credential holder's key proves the person is present; the wallet signature proves you control this address.",
  },
  {
    short: "Verify",
    title: "Verify the credential",
    why: "The verifier checks the chain, both signatures and revocation status, then issues a signed attestation.",
  },
  {
    short: "Register",
    title: "Register on-chain",
    why: "Records the attestation in the vLEI registry so launchers and vaults can gate on it (expires automatically).",
  },
] as const;

function Checks({ result }: { result: VerifyResult }) {
  return (
    <ul className="checks">
      {result.checks.map((c) => (
        <li key={c.id} className={c.ok === true ? "ok" : c.ok === false ? "bad" : "skip"}>
          <span className="icon" aria-hidden>
            {c.ok === true ? "✓" : c.ok === false ? "✗" : "·"}
          </span>
          <span>
            <span className="sr-only">{c.ok === true ? "passed: " : c.ok === false ? "failed: " : "skipped: "}</span>
            <b>{c.label}</b>
            {c.detail && <span className="small muted"> — {c.detail}</span>}
          </span>
        </li>
      ))}
    </ul>
  );
}

function StepTitle({ i }: { i: number }) {
  return (
    <div>
      <div className="step-title">
        <span className="step-num">{i + 1}</span> {STEPS[i].title}
      </div>
      <div className="step-why small muted">{STEPS[i].why}</div>
    </div>
  );
}
