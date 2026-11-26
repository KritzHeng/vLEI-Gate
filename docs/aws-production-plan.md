# vLEI-Gate: Path to Production on AWS

**Status:** plan. The hackathon build runs locally against BSC Testnet; nothing in it runs on AWS yet. This page maps each component to AWS and explains what AWS credits would fund.

## Pitch summary (one slide)

- **Problem:** institutional RWA launches on BNB Chain need to know *which legal entity* is investing, and that check must be verifiable and revocable, not a PDF in a back office.
- **Product:** vLEI-Gate verifies GLEIF vLEI credentials, records the result on-chain, and gates launch creation, investment and yield per legal entity. It is integrated with Flap Pool Launch, Atlas, CoinMarketCap and Cournot.
- **Why AWS:**
  - the verifier's signing key moves into **AWS KMS**;
  - the KERI infrastructure (witnesses, watchers, agents) runs in several regions;
  - compliance evidence goes to write-once storage;
  - **Amazon Bedrock** writes plain-language risk briefs for compliance officers.
- **Credits fund:** a production pilot with real vLEI credentials from a Qualified vLEI Issuer, first on BSC Testnet and then on BNB Chain mainnet.

## 1. Component map

| Today (hackathon) | Production on AWS | Why |
| --- | --- | --- |
| KYB Portal (Next.js) on localhost | **AWS Amplify Hosting** (or CloudFront + S3), with AWS WAF | Global, TLS and WAF without running servers; a stable URL for the Flap UI to link to |
| Backend verifier (FastAPI + keripy) on localhost | **Amazon ECS on Fargate** in private subnets behind an Application Load Balancer, in 2 AZs | keripy needs a long-running Python service; no hosts to patch |
| Verifier EIP-712 signing key in `.env` | **AWS KMS** asymmetric key `ECC_SECG_P256K1`; the backend calls `kms:Sign`, the key never leaves KMS, and **CloudTrail** logs every signature | Removes the biggest operational risk: the key that admits entities to the on-chain registry |
| Challenge store and nonces in process memory | **Amazon DynamoDB** with TTL | Works across tasks and restarts; single-use challenges hold under load |
| No KERI witnesses / watchers / KERIA (credentials passed as a bundle) | KERI **witnesses and watchers** on ECS Fargate in **3 regions** (e.g. ap-southeast-7 Bangkok, ap-southeast-1 Singapore, eu-central-1 Frankfurt); **KERIA** agents for holders | Real OOBI resolution, KEL/TEL monitoring and holder-signed presentations (closes README limitation 19) |
| Revocation handled by an admin click | Watcher events go to **Amazon EventBridge**, then an **AWS Lambda** that calls `revokeWallet` / `revokeEntity` with a KMS-held admin key behind a multisig policy | A TEL revocation reaches the chain within minutes, not "when someone notices" |
| Atlas relayer as a shell loop (`scripts/atlas_keeper.sh`) | **EventBridge Scheduler** runs a **Lambda** every 10–30 min; relayer key in KMS; **CloudWatch** alarms on staleness and CMC deviation | No laptop dependency; alerts before BNB launches hit `StalePrice` |
| API keys (CMC, Atlas, Cournot) in `.env` | **AWS Secrets Manager** with rotation, read through IAM task roles | No secrets in files or images |
| Cournot proofs and verification results as JSON files in `logs/` | **Amazon S3 with Object Lock** (write-once), queried with **Athena** | Tamper-evident audit trail for regulators and issuers |
| — | **Amazon Bedrock** (with Guardrails): a "compliance brief" summarising the vLEI chain, Cournot claim and evidence, and the Atlas/CMC checks for an offering | Officers read one page instead of raw JSON. The brief is labelled AI-generated and **never makes the decision**; decisions stay rule-based and on-chain |
| Public BSC RPC endpoints | Managed BNB Chain RPC provider, with an optional self-hosted BSC node on **Amazon EC2** for indexing | Reliable reads and event indexing for the activity feed |

## 2. Target architecture

```
Investor / issuer ──► CloudFront + WAF ──► Amplify (KYB Portal)
                                   │
                                   ▼
                     ALB ──► ECS Fargate: verifier API ──► KMS (secp256k1 Sign) ──► EIP-712 attestation
                                   │        │                                         │
                                   │        ├─► DynamoDB (challenges, nonces)         ▼
                                   │        ├─► Secrets Manager (CMC / Atlas / Cournot keys)   BNB Chain
                                   │        └─► S3 Object Lock (audit) ◄─ Bedrock brief        (VLEIRegistry,
                                   │                                                            Flap launchers,
   KERI witnesses / watchers / KERIA (ECS, 3 regions) ─► EventBridge ─► Lambda (revoke) ───────► vault, Atlas feed)
   EventBridge Scheduler ─► Lambda (Atlas relayer + CMC check) ────────────────────────────────►
                                   CloudWatch alarms: stale price, deviation, verifier errors, revocation lag
```

## 3. Milestones

| Phase | Scope | Exit criteria |
| --- | --- | --- |
| **M0: Hackathon** (done) | Local services, BSC Testnet, sample credentials | End-to-end flow with on-chain proofs (`docs/testnet-run.md`) |
| **M1: Hosted testnet pilot** (≈ 1 month) | Portal on Amplify, verifier on Fargate, KMS signing key, DynamoDB, Secrets Manager, scheduled Atlas relayer, CloudWatch alarms | Public URL; no secrets on disk; the Flap UI links to it |
| **M2: Real vLEI** (≈ 2–3 months) | Witnesses, watchers and KERIA in 3 regions; pinned GLEIF production root; credentials from a Qualified vLEI Issuer; watcher-driven revocation | A real legal entity verifies with its own vLEI wallet; a revocation reaches the chain automatically |
| **M3: Mainnet pilot** (≈ 3–6 months) | Audit, multisig + timelock admin, S3 Object Lock audit trail, Bedrock compliance briefs, one issuer pilot on BNB Chain mainnet | Audited contracts; first institutional offering |

## 4. How the credits would be used (12-month planning estimate)

These are planning estimates, not quotes. Actual usage depends on pilot volume.

| Area | Services | Share |
| --- | --- | --- |
| Verifier, portal and workers | ECS Fargate, ALB, Amplify, Lambda, EventBridge | ~30% |
| KERI network in 3 regions | ECS Fargate, networking | ~25% |
| AI compliance briefs | Amazon Bedrock (+ Guardrails) | ~15% |
| Data and audit | DynamoDB, S3 Object Lock, Athena | ~10% |
| Security | KMS, Secrets Manager, WAF, CloudTrail | ~8% |
| Monitoring and indexing | CloudWatch, optional EC2 BSC node | ~7% |
| Buffer | load tests, incident drills | ~5% |

## 5. Security principles

- **Keys:** the verifier, relayer and admin keys live in KMS. IAM limits each service to `kms:Sign` on its own key, and CloudTrail records every signature.
- **Least privilege:** one task role per service. The demo holder agent from the hackathon build is **not** deployed (`ENABLE_DEMO_AGENT=false`).
- **Fail closed:** a stale Atlas price, a CMC deviation or a missing Cournot assessment blocks the action, as it does today; CloudWatch alarms page the operator.
- **Privacy:** only `keccak256(LEI)` and the role go on-chain. Credential data stays in the verifier's private subnet and the encrypted S3 audit bucket.

## 6. Eligibility note

The AWS credits require AWS Activate eligibility, including a registered business, and each company can receive the award only once. The team must confirm this before applying.
