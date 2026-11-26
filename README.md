<!--
BEFORE SUBMITTING — fill every placeholder, then delete this comment:
  [ ] Demo video link, live app link, HackQuest project link
  [x] Atlas BNB/USD: signed Pull API reports (feedId 633) relayed to `AtlasSignedFeed` on BSC Testnet (Section 4.3)
  [x] Cournot live calls logged (Section 4.4); [ ] screenshot `docs/img/cournot-panel.png`
  [x] Flap enablement: all three launcher factories enabled at 1x on 2026-11-26 via Flap's testnet whitelister (Section 4.2); vault factory still requested
  [x] Flap UI ZIPs: launcher (v1 BNB 0x2791…), vault launcher (v2 USDT 0xEA3d…) and vault (0x3C90…, token 0xa272…) packaged in flap-launcher-ui/dist/
  [ ] Team (bottom of this file)
  [ ] git grep for API keys / private keys before making the repo public
-->

# vLEI-Gate

**Verifiable institutional KYB for tokenized RWA launches on BNB Chain, built on Flap Pool Launch.**

> Anyone can trade the token; first-round allocation **and** yield go only to verified legal entities.

vLEI-Gate lets only cryptographically verified legal entities, acting through authorized representatives, create a Flap launch, take part in its first round, and earn its tax yield. Identity comes from the GLEIF vLEI ecosystem (KERI / ACDC). Enforcement happens on-chain in our **Flap Launcher Factories** (who may create a launch), our **Launchers** (who may contribute and claim) and our **gated Vault** (who may stake and collect the 75% tax share). Raises are in USDT (Flap's mock USDT on testnet) or BNB. The token itself is Flap's standard tax token, created by the Flap Portal and freely tradable on the DEX after the launch.

| | |
| --- | --- |
| 🎥 Demo video | `<link>` |
| 🌐 Live app | `<link>` |
| 🏁 HackQuest | `<link>` |
| ⛓️ Network | BNB Smart Chain Testnet (Chapel, chainId 97) |
| ✅ Full testnet run | 37 txs: launch, graduation, claim, USDT yield, revocation ([`docs/testnet-run.md`](docs/testnet-run.md)) |

---

## 1. Problem

Institutions want to use on-chain RWA markets, but today they cannot answer three basic questions about a counterparty:

1. **Is this issuer a real legal entity?**
2. **Is the person behind this wallet authorized to act for it?**
3. **Is that authority still valid right now?**

Wallet-level KYC does not answer these questions, and most token launchpads do not ask them at all.

## 2. Solution

| Layer | What it does |
| --- | --- |
| **vLEI verification** | A verifier checks the full vLEI credential chain (root → QVI → LE → OOR/ECR), confirms the presenter controls both the credential holder's AID and the wallet, and issues a short-lived EIP-712 attestation. |
| **On-chain registry** | `VLEIRegistry` stores `keccak256(lei)`, role and expiry per wallet, and supports revocation (`revokeWallet`, `revokeEntity`). |
| **Gated launch via Flap Launcher Factories** | Our factories inherit Flap's `LauncherFactoryBase`. `Portal.newLauncher(factory, data)` calls our `_newLauncher`, which requires `registry.canLaunch(creator)`: only OOR holders with an authorized official role can create a launch. v1 (`VLEILauncherFactory`) raises in BNB; the v2 factories (`VLEILauncherFactoryV2`, `VLEIVaultLauncherFactoryV2`) have an immutable quote token per factory, BNB or an ERC20. The testnet v2 deployment uses Flap's mock USDT. |
| **Gated launcher** | Forked from Flap's `MintLauncher`. Only active vLEI wallets can `contribute` and `claim`, the creator must still be active, and each **legal entity** has a cap (in USDT 1:1 on the USDT path, in USD via a price feed on the BNB path). `contribute()` takes no arguments (Flap's launcher UI only calls zero-arg actions), so on the USDT path it pulls the user's approved USDT. Reaching `targetRaise` launches the token through the Portal in the same transaction. Revocation before the launch opens `withdrawContribution` / `cancelIfCreatorRevoked` + `refund`. |
| **Gated yield** | `VLEIDividendVaultV2` receives the VAULT tax slot (75% of the tax, in USDT). Only wallets active in `VLEIRegistry` can stake and claim; staking is required to earn. A revoked staker cannot claim and can be evicted by anyone (tokens returned, unclaimed rewards forfeited to the remaining stakers). Revenue that arrives with no stakers is held until at least 10,000 tokens are staked. |
| **Risk intelligence** | A live Cournot Intelligence Oracle probability (10Y Treasury yield, the offering's rate risk) decides whether investors must acknowledge a rate-risk notice before contributing. |
| **Market data** | Atlas BNB/USD reports, signature-checked on-chain (`AtlasSignedFeed`, feedId 633), price the BNB factory's minimum target and per-entity USD cap; CoinMarketCap cross-checks Atlas before a price is relayed and before a BNB contribution is allowed. The USDT path needs no feed. |

---

## 3. Demo Walkthrough

This is the journey that ran on the real BSC Testnet with `scripts/testnet_full_usdt.py` (vault factory, USDT quote, no Flap enablement). Every step, tx hash and amount is in [`docs/testnet-run.md`](docs/testnet-run.md#full-usdt-launch-vault-factory). The demo video follows the same script.

**Cast:** alice (OOR, CEO, entity *Siam*), bob (ECR, entity *Andaman*), erin (OOR, *Andaman*), outsider (no credential), admin (registry admin).

1. **KYB.** Each wallet presents its vLEI credential through the backend verifier (holder-AID signature + wallet signature) and registers the EIP-712 attestation in `VLEIRegistry`. Presenting alice's credential with another holder's AID is **rejected by the verifier** (`holder-AID signature mismatch`). ❌
2. **Create.** alice calls `Portal.newLauncher(VLEIVaultLauncherFactoryV2, VLEIMintConfig)`: target 3,000 USDT, cap 2,000 USDT per entity, 24 h sale, token address vanity-mined to end in `7777`. ✅
3. **Gate.** The outsider approves 500 USDT and calls `contribute()` → **reverted (`NotVerified`)**. ❌
4. **Entity cap.** bob approves and contributes 1,500 USDT. erin (same entity) approves 1,000, but `contribute()` pulls only the **500** left on *Andaman*'s 2,000 cap; her second call → **reverted (`EntityCapReached`)**. ❌
5. **Launch.** alice contributes 1,000 USDT → 3,000 reached; the same tx launches the token on the Portal and it **graduates** (`FlapTokenGraduated`, 4.76M gas). ✅
6. **Claim + stake.** bob 250,000, erin 83,333.33, alice 166,666.67 tokens (pro rata to USDT); all three stake in the gated vault. ✅
7. **Trading is open.** The outsider buys with 500 USDT on the DEX and sells 30%. The sell tax is liquidated and Flap's keeper (`batchDispatch`) delivers **12.34 USDT** (the VAULT slot) to the vault. ✅
8. **Revocation.** The admin revokes erin (simulating a watcher that saw a TEL revocation). erin's `vault.claim()` → **reverted (`NotVerified`)**. ❌ bob calls `evict(erin)`: her 83,333.33 tokens are returned and her 2.47 USDT of rewards are forfeited to the remaining stakers.
9. **Yield.** bob claims **9.25 USDT** (his share plus 3/4 of erin's forfeit). The outsider tries to stake → **reverted (`NotVerified`)**. ❌ The outsider transfers 1 token to another unverified wallet: allowed (known limitation 1).

The earlier BNB run on the v1 factory (`scripts/testnet_partial.py`, same file) covers `withdrawContribution` after a contributor's revocation. `CreatorNotAuthorized` (ECR trying to create), non-pinned roots and the v1 claim path are covered by unit / fork tests and `scripts/e2e_local.sh` (anvil fork with the live Flap Portal).

On the USDT path the user first **approves the launcher on the USDT token in their wallet** (the Flap UI cannot approve), then presses *Contribute*. Contribute / claim / refund are in our **Flap launcher UI** (`flap-launcher-ui/`), hosted by Flap. The KYB Portal's *Launches* page lists launchers read-only and has clearly labeled local test helper buttons.

---

## 4. Sponsor Integrations

### 4.1 BNB Chain — Developer Track (RWA)

- Compliance-gated RWA issuance on BSC Testnet: only vLEI-verified legal entities create launches, receive the first-round allocation, and earn the token's tax yield.
- Raises and yield in a stablecoin (USDT quote), with a per-legal-entity cap in USDT.
- Transfer-level gating follows the allowlist model of **CAS20 (BEP-702)** and is on the roadmap (see Section 9).

### 4.2 Flap — Build on Pool Launch

- **Launcher Factories** (all inherit Flap's `LauncherFactoryBase` from `flap-sh/FlapPoolLaunchVaultExample`; `_newLauncher` is the vLEI gate: `registry.canLaunch(creator)` or revert `CreatorNotAuthorized`; launchers are ERC-1967 beacon proxies, upgradable only by the Flap Guardian):
  - v1 `VLEILauncherFactory`: BNB quote, tax Burn 10 / LP 15 / DIVIDEND 75 (Flap's dividend tracker, all holders).
  - v2 `VLEILauncherFactoryV2` and `VLEIVaultLauncherFactoryV2`: one codebase, immutable quote per factory (`address(0)` = BNB, or an 18-decimal ERC20). The testnet deployment uses Flap's mock USDT `0x190C989D5665a0e404B444b53CAE9AbCfb600157` ($1 on the Portal). The vault variant uses Burn 10 / LP 15 / **VAULT 75**.
- **Vault Factory:** `VLEIDividendVaultFactoryV2` (`DirectLaunchVaultFactoryBase`, `pl-v1`). `newVault` (onlyHub) accepts only a launcher from the paired launcher factory, the matching quote, a VAULT slot of exactly 7500 bps and `commissionReceiver == 0`. One beacon-proxy `VLEIDividendVaultV2` per token; Guardian-only upgrades. The Portal records it: `Portal.getLaunchVault(token)` returned our vault on testnet.
- **Launcher:** keeps the economics of Flap's `MintLauncher` (1M supply, 50% pool / 50% claimed pro rata, 3% buy / 5% sell tax) and adds the vLEI checks on `contribute` and `claim`, plus `withdrawContribution`, `cancelIfCreatorRevoked` and `refund`. All UI actions are zero-arg; `contributeAmount(uint256)` exists for scripts.
- **Portal:** `0x000042108465206185A077Edc3F3fd2b49060000` (BSC Testnet, v1.2.0). `Portal.newLauncher{value: SALT_LOCK_FEE}(factory, abi.encode(VLEIMintConfig))`; the salt makes the token address end in `0x7777`. The Portal deploys the token (`launchTaxTokenV2`), seeds the pool and, for the vault variant, creates the vault. Read on chain: creation floor **1,500 USDT**, graduation floor **3,000 USDT** (our demo raised 3,000 and graduated).
- **No developer commission:** `commissionReceiver = address(0)`, enforced; 100% of vault revenue goes to stakers.
- **Launcher UI:** `flap-launcher-ui/vlei-gate-launcher/` (`manifest.json` kind `launcher-ui`, `Component.tsx`, `i18n.json`), built from Flap's `flap-vault-component-template`, checked with `yarn launcher:check-source` and packaged in `flap-launcher-ui/dist/`. It shows the viewer's vLEI status, raised / target, remaining entity cap, and contribute / claim / refund / withdraw buttons, with a link to the KYB Portal for unverified wallets. Three ZIPs are packaged: `vlei-gate-launcher.zip` (bound to the v1 BNB factory `0x2791…Eb3b`), `vlei-gate-vault-launcher.zip` (v2 USDT vault launcher factory `0xEA3d…9CeD`) and `vlei-gate-vault.zip` (stake / claim / evict; vault factory `0x3C90…9c03`, token `0xa272…7777`).
- **Factory enablement:** the testnet Portal v1.2.0 does **not** require it: our full USDT run used unopened factories. We still ask Flap to open them (`setLauncherFactoryMultiplier` / `setVaultFactoryMultiplier`) for the UI status, the floor multiplier and the low-risk badge; the vault shows as unverified on Flap until audited. On an anvil fork we enable by impersonating the Portal admin (`contracts/script/enable_factory_fork.sh`). Status (2026-11-26): the three launcher factories are **enabled at 1x** on the Portal (`launcherFactoryMultiplier` = `true, 10000`) through Flap's testnet helper `LauncherFactoryWhitelister` `0x77779969a11eff7582f3bCf48135A846A3457777` (`whitelist(factory)`): v1 BNB `0x2791…Eb3b` tx `0xa41bf4b7…6d046652`, v2 USDT vault `0xEA3d…9CeD` tx `0x77dec1f7…18886212`, v2 BNB (Atlas) `0x3949…48a4` tx `0x7a64226b…9650b9`. The vault factory `0x3C90…9c03` (`vaultFactoryMultiplier` = `false`) is not covered by the helper and is requested from Flap.

| Item | Address |
| --- | --- |
| Flap Portal (BSC Testnet) | `0x000042108465206185A077Edc3F3fd2b49060000` |
| Flap mock USDT (quote) | `0x190C989D5665a0e404B444b53CAE9AbCfb600157` |
| `VLEIVaultLauncherFactoryV2` / `VLEIDividendVaultFactoryV2` (USDT) | `0xEA3d889e5EA5f684268cDEcc45CE77322F0D9CeD` / `0x3C90db983d2eE6D3aa8fD88d6CF5Ae8535d49c03` |
| `VLEIMintVaultLauncherV2` impl / beacon | `0x16B12A2f98418c50017CE4FD2F3e127d29e4DB0E` / `0xD9c43fd19bdF75641116F023695ee3C8496aaA32` |
| `VLEIDividendVaultV2` impl / beacon | `0x826C9905AfF478a5b1D36E1C274D3c8973695E8D` / `0xdfAA5b2f635937924289363DA5a1b71Df295eF80` |
| `VLEILauncherFactoryV2` (USDT, plain dividend) / impl / beacon | `0xb682af7AB04eCa86A4F14d08BBC203040399715E` / `0xe6Ef701836c24B294A2b3a50b2DdeFA558937E05` / `0xa242ac138f934e6B6260E5E369d469cd507C1c57` |
| v1 `VLEILauncherFactory` (BNB) | `0x279141bABEEEFF178E7ADad7db131Eb48763Eb3b` |
| v1 BNB vault pair: `VLEIVaultLauncherFactory` / `VLEIDividendVaultFactory` | `0x3fF9509b93AA9a20c446e63c7D45d7946FF3c1c6` / `0x3A79DA23F3a31D9acA6c4017eff6aEfe1651c548` |
| Demo launcher / token (`...7777`, graduated) / vault | see Section 6 |

### 4.3 CoinMarketCap × Atlas

Honest status:

- **CoinMarketCap (off-chain):** `GET /api/market/cmc` proxies `/v1/cryptocurrency/quotes/latest` server-side (API key never reaches the client).
- **Atlas (on-chain, signed): `AtlasSignedFeed` `0x34aa570cDa23282af94aA3CE4232bD4B18B644d5`.** Atlas' Pull API returns a signed report (`payload` + 65-byte `signature`). Anyone can relay it with `submit(payload, signature)`: the contract recovers the signer over `keccak256(payload)`, requires the published Atlas signer `0x59eD…C600`, decodes the `feedId | price | timestamp` entry, rejects replays, rollbacks and timestamps more than 60 s ahead, and exposes it as an aggregator feed (8 dp). Format and evidence (all three signed examples in the Atlas docs recover the Atlas signer): [`docs/atlas-payload-format.md`](docs/atlas-payload-format.md). Relayer: `scripts/push_atlas_price.py` (checks `consensusStatus`, freshness and the signature off-chain first).
- **Status: live with real Atlas prices (2026-11-26).** Atlas BNB/USD is feedId **633**. We identified it by matching the Pull API history against Atlas' public BNB/USD push feed on BSC mainnet (`0x9c0517f5b4c8657c7f18d68d2d79e2b3b1cd6438`, `description()` = "bnb/usd"): feedId 633 equals that feed exactly on 12 of 12 consecutive updates; the other two candidates near the BNB price (746, 759) differ. `setFeedId(633)` tx `0xc44b3231010001640699ba5256ad83ecf16e978c98c558c799462b084fc09c4a`; first real price $559.29, submit tx `0xd641ffcdcf6da68ec03dd3c8934bd6e3880962eb5f23cbbe87dfadd7e6dbfc38`. The relayer must run at least hourly (`maxPriceAge`) for BNB launches on the v2 factory; a stale price makes them revert, which is the intended fail-safe. The v1 BNB factory (`0x2791…Eb3b`, immutable feed) still uses the `MockPriceFeed` (`0x6877eE3be089f12C4Fc78098E255AEC381a1dF41`, labeled *MOCK FEED* in the UI).
- **Enforcement:** on the BNB path the feed (staleness-checked against `maxPriceAge`, 1 h) values contributions against the per-entity USD cap and the factory's minimum target: v1 factory with the mock, v2 factory `0x3949…48a4` with `AtlasSignedFeed`. The USDT path counts 1 USDT = $1 and reads **no** feed. The KYB Portal's Intelligence card reads the feed of `NEXT_PUBLIC_PRICE_FEED_FACTORY_ADDRESS` (the v2 Atlas factory in `frontend/.env.local`) and shows it next to the CMC price with the deviation, labeled *Atlas (signed, on-chain)*.
- **On-chain proof (BSC Testnet, 2026-11-26):** on the Atlas-priced BNB factory, a 1 BNB target is rejected (`TargetBelowMinimum`, Atlas values it at ~$560 < $1,600) while 3.2 BNB ($1,791.90) creates launcher `0x206dB9B3b73Ca3f57a0cB1C8C3fc83cFDfcD609b`; with a $10 per-entity cap, a 0.01 BNB contribution (~$5.60) succeeds and a second one reverts `CapExceeded`. Tx links: [`docs/testnet-run.md`](docs/testnet-run.md#atlas-priced-bnb-launch-2026-11-26); script: `scripts/testnet_atlas_bnb.py`.
- **CoinMarketCap × Atlas cross-check (core function, two places):** (1) the relayer `scripts/push_atlas_price.py` refuses to put an Atlas report on-chain when it differs from the CoinMarketCap BNB price by more than 2% (`--max-deviation-bps`, fails closed if CMC is unreachable); (2) the backend `GET /api/market/price-check` compares the on-chain Atlas price with CMC (status `ok` / `deviation` / `stale` / `unavailable`), and the KYB Portal disables *Contribute* on Atlas-priced BNB launches unless the check passes, showing both prices and the deviation. Thresholds: `PRICE_DEVIATION_MAX_BPS` (200), `PRICE_MAX_AGE_SECONDS` (3600).
- One-page write-up: [`docs/cmc-atlas-writeup.md`](docs/cmc-atlas-writeup.md)

| Item | Address / Endpoint |
| --- | --- |
| Atlas BNB/USD feed | `AtlasSignedFeed` `0x34aa570cDa23282af94aA3CE4232bD4B18B644d5` (signed Pull API reports, feedId 633, live); v1 factory: `MockPriceFeed` `0x6877eE3be089f12C4Fc78098E255AEC381a1dF41` |
| Atlas endpoint | `POST /report/v1/price/latest` (`signed: true`), via `scripts/push_atlas_price.py` |
| CMC endpoint | `/v1/cryptocurrency/quotes/latest` |

### 4.4 Cournot Integration

**What it does for the project.** The demo offering (*Siam Tokenized Treasury*, VLDT) is a tokenized-Treasury RWA. Its main market risk is interest rates: when yields rise, Treasury prices fall. vLEI-Gate asks the **Cournot Intelligence Oracle** for the market-implied probability of a higher-yield outcome and uses that probability to decide whether investors must acknowledge a rate-risk notice before they can contribute.

**Where and how it calls Cournot.** `backend/app/oracle/cournot.py`, exposed as `POST /api/oracle/cournot-risk`. It makes the same HTTP calls as the official skill client (`cournot-ai/cournot-skills`, `scripts/cournot-client.mjs`):

| Step | Call | Cost |
| --- | --- | --- |
| Find the market | `POST https://interface.cournot.ai/intelligence/v1/resolve` `{"message", "limit"}` | free |
| Get the probability | `POST https://interface.cournot.ai/intelligence/v1/probability` `{"message": "<question>", "market_ids": ["2878523"]}` | Cournot free quota (3 per IP) or `COURNOT-API-KEY` header |

- **Question:** "Will the 10-year US Treasury yield be above 4.74% on December 31, 2026?" (`COURNOT_QUESTION`). a `/resolve` search for a 10Y-yield question returned Kalshi market **2878523** ("above 4.74 on Dec 31, 2026") with confidence 0.845 (`COURNOT_MARKET_IDS`); the other candidates we tried are in `logs/cournot/resolve/`.
- A live call is made only when the user presses *Run a new live Cournot call* (`refresh: true`). Otherwise the backend serves the latest logged **live** result with its timestamp (`GET /api/oracle/cournot-latest`), so a demo does not use up the quota. There is no mock path: until a live call has been logged the endpoint returns 404; a failed refresh returns 402 (quota used up), 429 (throttle or rate limit) or 502, and if a cached live result exists it is returned with `refreshError` instead.

**How the probability is used (the decision).** `probability >= COURNOT_RISK_THRESHOLD` (0.5) marks the offering **"Rate risk elevated"**. On every offering page (the rate-risk notice currently applies to all offerings, as the demo issuer is a Treasury fund) the *Contribute* button stays disabled until the investor ticks *"I have reviewed this rate-risk assessment and want to proceed"* (`RiskGate` + `needsConfirmation` in `frontend/components/`). Below the threshold the page shows a green note and no acknowledgement is needed. The latest result is p = **0.74**, so the gate is active. The gate **fails closed**: until a live Cournot assessment is loaded, *Contribute* stays disabled. Live calls are throttled server-side (`COURNOT_MIN_REFRESH_SECONDS`, 300 s) and responses are validated (a missing or out-of-range probability is rejected, never treated as 0).

**Where users see the claim and evidence.** `/verify` → *Risk & market intelligence* → *Rate risk (Cournot Intelligence Oracle)*:
- the question sent to Cournot,
- **the claim evaluated**: the matched market's title, with its resolution rules (`markets[0].market_info.description`),
- the probability, the threshold and the market match confidence,
- **the evidence**: Cournot's `basis` entries (source, summary, time, link; here the Kalshi market page),
- billing (`free_quota` / key), latency, timestamp and the log file that proves the call.

The offering page repeats the decision in a short banner that links to the full card. **Text added by vLEI-Gate** (the interest-rate interpretation) is shown with an *"Added by vLEI-Gate"* badge, separate from what Cournot returned. Screenshot: `docs/img/cournot-panel.png` `<add>`

**Proof of successful live calls** (sanitized: client IP redacted, no API key used; Cournot's probability response carries no request id, so the log file is the reference):

| Time (UTC) | Caller | Claim (Cournot market 2878523) | Probability | Evidence (basis) | Billing | Log |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-11-26 07:12:22 | first live test (script) | 10Y yield above 4.74 on Dec 31, 2026? | **0.74** | Kalshi YES 0.7400 (07:09:40 UTC) | free_quota | [`20261126T071222Z-probability.json`](logs/cournot/live/20261126T071222Z-probability.json) |
| 2026-11-26 07:15:54 | backend `POST /api/oracle/cournot-risk` (`refresh: true`) | same | **0.74** | Kalshi | free_quota | [`20261126T071554Z-probability.json`](logs/cournot/live/20261126T071554Z-probability.json) |

Reproduce: `curl -X POST localhost:8000/api/oracle/cournot-risk -H 'content-type: application/json' -d '{"refresh":true}'` (spends one call), then `curl localhost:8000/api/oracle/cournot-log`.

**Limitation:** the decision is enforced in the KYB Portal, not by the contracts, so a direct contract call bypasses it (Limitation 16).

---

## 5. Architecture

```text
+-------------------------------------------+   +--------------------------------------+
|     vLEI KYB PORTAL (Next.js, frontend/)  |   | FLAP LAUNCHER / VAULT UI             |
|  KYB Panel | Intelligence | Launches |    |   | (flap-launcher-ui, hosted by Flap):  |
|  Admin (revokeWallet / revokeEntity)      |   | vLEI status, contribute / claim /    |
+------+-------------------+----------------+   | refund; stake / claim / evict        |
       | ACDC + AID sig    | risk / price       +------------------+-------------------+
       | + wallet sig      | (CMC, feed)                           |  user approves USDT
       v                   v                                       |  in wallet first
+------------------------------------------+                       |
|     BACKEND VERIFIER (Python / keripy)   |                       |
|  /api/vlei/verify   root pin, KEL/TEL,   |                       |
|                     chain shape, dual    |                       |
|                     challenge, role      |                       |
|  /api/oracle/cournot-risk  (rate risk)   |                       |
|  /api/market/cmc           (proxy)       |                       |
+--------------------+---------------------+                       |
                     | EIP-712 attestation                         |
                     v                                             v
+---------------------------------------------------------------------------------------+
|                              BNB SMART CHAIN TESTNET (97)                             |
|                                                                                       |
|  VLEIRegistry <-- canLaunch(creator) -- VLEIVaultLauncherFactoryV2 (quote = USDT)     |
|  - keccak256(lei), role, expiresAt         ^ newLauncher (onlyHub)                    |
|  - revokeWallet / revokeEntity             |                                          |
|      ^   ^                          Flap Portal --- launchTaxTokenV2 ---+             |
|      |   |                                 | deploys beacon proxy       |             |
|      |   | isActive, leiHashOf             v                            v             |
|      |   +---------------------- VLEIMintVaultLauncherV2 ------> Flap tax token ...7777|
|      |    contribute(): pulls approved USDT,  (raise 3,000 USDT)  + DEX pool (USDT)   |
|      |    entity cap 1:1 in USDT                                  freely tradable     |
|      |                                                                  | 3% / 5% tax |
|      |                                 Portal -> VLEIDividendVaultFactoryV2 |           |
|      |                                              | newVault          v             |
|      | isActive at stake / claim       VLEIDividendVaultV2 <-- TaxProcessor           |
|      +-------------------------------  stake / claim / evict   (VAULT 75%, in USDT;   |
|                                        pays verified stakers   dispatch by keeper or  |
|                                                                anyone)                |
|  v1 (BNB): VLEILauncherFactory -> VLEIMintLauncher, USD cap via price feed            |
+---------------------------------------------------------------------------------------+
```

### Sequence (USDT, vault factory)

```text
Institution          KYB Portal        Verifier          Flap Portal / Launcher / Vault (BSC Testnet)
    |                    |                 |                        |
    |-- 1 ACDC --------->|                 |                        |
    |<- 2 challenge -----|                 |                        |
    |-- 3 sign (holder AID + wallet) ----->|                        |
    |                    |                 |-- root / KEL / TEL /   |
    |                    |                 |   chain / role checks  |
    |                    |<- 4 EIP-712 ----|                        |
    |-- 5 register ---------------------------------------------->  | Registry
    |-- 6 risk check --->|-- 7 Cournot --->|                        |
    |-- 8 Portal.newLauncher(vaultFactoryV2, cfg) ---------------->  | factory: canLaunch? OK / REVERT
    |-- 9 approve USDT + contribute (unverified) ----------------->  | REVERT NotVerified
    |-- 10 approve USDT + contribute (verified, entity cap) ------>  | OK / EntityCapReached; target ->
    |                    |                 |                        |   Portal: token + pool + vault
    |-- 11 claim, stake in vault --------------------------------->  | OK (verified)
    |   (DEX trades by anyone -> tax -> TaxProcessor -> vault, USDT)  |
    |-- 12 revoke ------------------------------------------------>  | Registry
    |-- 13 vault.claim (revoked) --------------------------------->  | REVERT NotVerified
    |-- 14 evict(revoked) by anyone ------------------------------>  | tokens back, rewards forfeited
    |-- 15 same ACDC, other holder AID --->| REJECT (AID sig)       |
```

## 6. Deployed Contracts (BSC Testnet)

| Contract | Address | BscScan |
| --- | --- | --- |
| `VLEIRegistry` | `0x721013977E002A21274CC304c1b980c80A8689EF` | [BscScan](https://testnet.bscscan.com/address/0x721013977E002A21274CC304c1b980c80A8689EF) |
| `VLEILauncherFactory` | `0x279141bABEEEFF178E7ADad7db131Eb48763Eb3b` | [BscScan](https://testnet.bscscan.com/address/0x279141bABEEEFF178E7ADad7db131Eb48763Eb3b) |
| `VLEIMintLauncher` implementation | `0x4df3c52f83990bD2d8a4e0AFb7c314ebEfd05A74` | [BscScan](https://testnet.bscscan.com/address/0x4df3c52f83990bD2d8a4e0AFb7c314ebEfd05A74) |
| `VLEIMintLauncher` beacon | `0x4E8BEC1D41B213f5B9E32A219694fC7d54907268` | [BscScan](https://testnet.bscscan.com/address/0x4E8BEC1D41B213f5B9E32A219694fC7d54907268) |
| Demo launcher (beacon proxy) | `0x721765B1022145ebE90ba7B06FBB06C942965d92` | [BscScan](https://testnet.bscscan.com/address/0x721765B1022145ebE90ba7B06FBB06C942965d92) |
| Demo token (Flap tax token, `...7777`, USDT quote, graduated) | `0xa27228Eec1d484A32aDD3AfCEb2Ad01cc6b07777` | [BscScan](https://testnet.bscscan.com/address/0xa27228Eec1d484A32aDD3AfCEb2Ad01cc6b07777) |
| `VLEIVaultLauncherFactoryV2` (USDT quote, gated vault) | `0xEA3d889e5EA5f684268cDEcc45CE77322F0D9CeD` | [BscScan](https://testnet.bscscan.com/address/0xEA3d889e5EA5f684268cDEcc45CE77322F0D9CeD) |
| `VLEIDividendVaultFactoryV2` (USDT quote) | `0x3C90db983d2eE6D3aa8fD88d6CF5Ae8535d49c03` | [BscScan](https://testnet.bscscan.com/address/0x3C90db983d2eE6D3aa8fD88d6CF5Ae8535d49c03) |
| `VLEILauncherFactoryV2` (USDT quote, plain dividend) | `0xb682af7AB04eCa86A4F14d08BBC203040399715E` | [BscScan](https://testnet.bscscan.com/address/0xb682af7AB04eCa86A4F14d08BBC203040399715E) |
| Demo USDT launcher (vault factory, beacon proxy) | `0x9fEE3844a9E0D38A10E9cC53Adb6c7FFa4F08f27` | [BscScan](https://testnet.bscscan.com/address/0x9fEE3844a9E0D38A10E9cC53Adb6c7FFa4F08f27) |
| Demo vault (`VLEIDividendVaultV2`, pays USDT to verified stakers) | `0xE45AdBf496Ad04145fC60bB756bf1917dF642433` | [BscScan](https://testnet.bscscan.com/address/0xE45AdBf496Ad04145fC60bB756bf1917dF642433) |
| `MockPriceFeed` (BNB/USD of the v1 factory, whose feed is immutable) | `0x6877eE3be089f12C4Fc78098E255AEC381a1dF41` | [BscScan](https://testnet.bscscan.com/address/0x6877eE3be089f12C4Fc78098E255AEC381a1dF41) |
| `AtlasSignedFeed` (Atlas BNB/USD from signed Pull API reports, feedId 633) | `0x34aa570cDa23282af94aA3CE4232bD4B18B644d5` | [BscScan](https://testnet.bscscan.com/address/0x34aa570cDa23282af94aA3CE4232bD4B18B644d5) |
| `VLEILauncherFactoryV2` (native BNB quote, priced by `AtlasSignedFeed`) | `0x394928211B03Eb74a6f7061a56973F77A7fC48a4` | [BscScan](https://testnet.bscscan.com/address/0x394928211B03Eb74a6f7061a56973F77A7fC48a4) |
| `VLEIMintLauncherV2` implementation / beacon (of the BNB v2 factory) | `0x9e03a4C1800dcD775bAb42Bf8e0F899c91CC8Ef5` / `0xE6E5FbEF9E88BB63734081b60BCedA7FCe62065c` | [impl](https://testnet.bscscan.com/address/0x9e03a4C1800dcD775bAb42Bf8e0F899c91CC8Ef5) · [beacon](https://testnet.bscscan.com/address/0xE6E5FbEF9E88BB63734081b60BCedA7FCe62065c) |

Partial BNB run on the v1 factory (verify → register → newLauncher → contribute → revoke → withdraw, no launch; superseded by the full USDT run below): [`docs/testnet-run.md`](docs/testnet-run.md)

Full USDT journey on the vault factory (launch, claim, gated vault yield, revocation): newLauncher [`0xd4edfad7…`](https://testnet.bscscan.com/tx/0xd4edfad7e38f4f7381e3696d774ea074397f48d35c73560ac7efdc3cad94f4e5) · contribute [`0xad7caa68…`](https://testnet.bscscan.com/tx/0xad7caa6885985530f2e0f92549dca3599ffac6641d986d0bd9e59169788f57ed) · launch [`0x726e10d1…`](https://testnet.bscscan.com/tx/0x726e10d11225a21299b8a709c80237afb5a423541ab423610a5a016c4c2d905f) · claim [`0x6b6f84d9…`](https://testnet.bscscan.com/tx/0x6b6f84d93876948cbf84a48c6cbd893a8887fb636f52757b7ae991267ff53e4e) · vault yield claim [`0x0fd77dcd…`](https://testnet.bscscan.com/tx/0x0fd77dcdc0b8e29beff85705751f35d595248266e2e866f8dce05bcc4523d843); all 37 txs in [`docs/testnet-run.md`](docs/testnet-run.md#full-usdt-launch-vault-factory)

Source code (checked 2026-11-26): the five v1 contracts above (registry, factory, launcher implementation, beacon, mock feed) and the v2 contracts (the three v2 factories plus their implementations and beacons, listed in Section 4.2) are verified on BscScan, e.g. [VLEILauncherFactory](https://testnet.bscscan.com/address/0x279141bABEEEFF178E7ADad7db131Eb48763Eb3b#code) and [VLEIVaultLauncherFactoryV2](https://testnet.bscscan.com/address/0xEA3d889e5EA5f684268cDEcc45CE77322F0D9CeD#code); they are **not** on Sourcify. The Atlas deployments (`AtlasSignedFeed`, the BNB `VLEILauncherFactoryV2` `0x3949…48a4` and its implementation and beacon) are verified on both BscScan and [Sourcify](https://repo.sourcify.dev/97/0x34aa570cDa23282af94aA3CE4232bD4B18B644d5) (exact match). The v1 BNB vault pair (`0x3fF9…c1c6` / `0x3A79…c548`) is not verified.

Verifier signer address (for EIP-712): `0xB51CfC1705ff83FBf21fDfD7bfE0588281FbD4C5`

---

## 7. How Verification Works

### 7.1 Verifier checks (`POST /api/vlei/verify`)

1. **Root pinning:** the chain must terminate at the pinned root AID.
2. **Signature validity:** every credential is validated against the issuer's *latest* KEL key state.
3. **Chain structure:** edges and schemas match the expected vLEI shape. OOR is issued by a QVI holding an OOR Authorization from the LE. ECR is issued by the LE directly, or by a QVI holding an ECR Authorization.
4. **Revocation:** the TEL of **every** credential in the chain is checked, not just the leaf.
5. **Holder control:** the holder AID signs a challenge (`nonce`, `wallet`, `chainId`) with its current keys.
6. **Wallet control:** the wallet signs the same challenge.
7. **Role policy:** the role must be authorized for the requested action.
8. **Attestation:** EIP-712 signature over `(wallet, leiHash, role, nonce, expiresAt)` with domain `(name, version, chainId, verifyingContract)`.

### 7.2 Role policy

| Action | Required credential |
| --- | --- |
| Create a launch (`Portal.newLauncher`) | OOR with an authorized official role (e.g., CEO, CFO) |
| Contribute / claim | OOR or ECR from an active entity |
| Trade the token after launch | Anyone (not gated, see Section 8) |

ECR roles are free text defined by the issuing entity, so an ECR alone never grants launch rights.

### 7.3 On-chain enforcement

- `VLEIRegistry.isActive(wallet)` requires: registered, wallet and entity not revoked, `block.timestamp < expiresAt`. `canLaunch` additionally requires the OOR officer role. Only the registry admin can revoke; the verifier role can only register.
- **Create:** `_newLauncher` (reached only through `Portal.newLauncher`, `onlyHub`) requires `registry.canLaunch(creator)`, else `CreatorNotAuthorized`, and a sale of at most 30 days. Minimum target: **1,500 USDT** on the USDT factories (1:1, no feed; matches the Portal's creation floor); **$1,600** at the feed price on the BNB factory (`TargetBelowMinimum`, or `StalePrice` / `InvalidPrice`). Only launchers with `factory.isLauncher(addr) == true` are ours; the UIs read only those.
- **Contribute:** requires the sender to be active (`NotVerified`), the creator to still pass `canLaunch` with the same LEI (else `IssuerNotActive`; the UIs show the sale as *paused*), and the sender's **entity** (`leiHash`, summed over all its wallets) to stay within `capUsdPerEntity`.
  - USDT path: `msg.value` must be 0. The zero-arg `contribute()` pulls **min(allowance, balance, target − raised, entity cap left)** of the approved USDT, credited by balance delta; it reverts `EntityCapReached`, `NoAllowance` or `NoQuoteBalance` when that is 0. Cap and target are in USDT, 1 USDT = $1.
  - BNB path (v1): payable; the cap is valued at the feed price (`CapExceeded`, `StalePrice`); excess over the target is refunded.
- **Launch:** the contribution that reaches `targetRaise` calls `Portal.launchTaxTokenV2` in the same transaction (USDT: exact `forceApprove` to the Portal, reset to 0 afterwards) and needs `gasleft() >= MIN_LAUNCH_GAS` (7M; use a gas limit of about 9M). If the Portal launch reverts, the launcher catches it (`LaunchFailed`, status Failed) and refunds open. 1,500–2,999 USDT launches but does not graduate; ≥ 3,000 emits `FlapTokenGraduated`.
- **Claim:** `claim` requires the caller to be active. A revoked contributor's tokens stay reserved until the wallet is verified again.
- **Revocation before launch:** a revoked contributor may `withdrawContribution`; if the creator is revoked, anyone may `cancelIfCreatorRevoked` and every contributor can `refund`. Mere expiry does not open these paths (an expired creator's sale can be cancelled only after `expiresAt` + 7 days). After the deadline below target, `refund` opens as in Flap's `MintLauncher`.
- **Vault:** `stake` and `claim` require `isActive` (claim also the same `leiHash` the stake was made under). `unstake` is never gated, but a revoked caller exits fully and forfeits. `evict(account)` is open to anyone once the account is revoked, moved to another LEI, or expired for more than 7 days: its tokens are returned and its unclaimed USDT is forfeited pro rata to the remaining stakers. Revenue is counted by balance delta (`sync()` before every action), O(1) per call. Revenue with no stakers is held until `HELD_RELEASE_MIN_STAKE` (10,000 tokens) is staked.
- **Admin surface:** the factory owner can only tune `maxPriceAge` / `minTargetUsd`; vault factories have no owner. Only the Flap Guardian can upgrade launcher and vault implementations (beacons).

---

## 8. Threat Model & Known Limitations

vLEI-Gate verifies **who an institution is and what authority its representative holds** at the moment of verification, and enforces that result on-chain.

### Trust assumptions

| Component | We trust that… |
| --- | --- |
| Root of trust | The verifier only accepts chains anchored to a pinned root AID. In production this is GLEIF's root AID. **In this demo it is a test root generated with `keripy`.** |
| Verifier service | It performs the checks in 7.1 honestly and its signing key is not compromised. |
| Watchers | At least one configured watcher returns current, non-duplicitous KEL and TEL state. |
| Contract admin | The admin key (revocation, verifier rotation) is held securely. |
| Flap | The Flap Portal, its token implementation, its TaxProcessor / keepers and the Flap Guardian (upgrade authority over our launchers and vaults) behave as documented. |
| Quote token | 1 USDT = $1. On testnet the quote is Flap's mock USDT. |

### Threats mitigated

| Threat | Mitigation |
| --- | --- |
| Forged credential / fake root | Root AID pinning + signature validation against KEL |
| Reusing someone else's credential with another wallet | Holder-AID challenge + wallet signature |
| Signatures from rotated (compromised) keys | Validation against latest KEL state |
| Credential revoked before verification | TEL check across the whole chain |
| Unauthorized role acting for the entity | Role policy (7.2) enforced on-chain in the factory |
| Attestation replay across chains / contracts | EIP-712 domain separation + nonce |
| Unverified wallets in the first round | `contribute` and `claim` require an active registration |
| One entity splitting its allocation across wallets | Cap per legal entity (`leiHash`), not per wallet |
| Issuer losing its authority mid-sale | Contributions stop; `cancelIfCreatorRevoked` + `refund` |
| Unverified holders collecting the tax yield | Vault `stake` / `claim` require an active registration |
| Revoked entity keeping its yield | Claim blocked; `evict` returns tokens and forfeits rewards to remaining stakers |
| A dust staker sweeping revenue held while nobody staked | Held revenue released only once 10,000 tokens are staked |

### Known limitations

1. **Tokens can reach unverified wallets after the launch (High for regulated RWA).** The token is Flap's standard tax token, created by the Portal, with no transfer hook. Anyone can buy it on the DEX or receive it by transfer (shown on testnet). The gate covers creation, the first-round allocation and the yield, not holding or trading. *Roadmap:* transfer-level gating with CAS20 (Section 9).
2. **Yield requires staking; timing games for verified holders (Medium).** Unstaked holders, verified or not, earn nothing. Because `TaxProcessor.dispatch()` is permissionless and moving tokens into or out of the vault is not taxed, a verified holder can stake around a dispatch and earn like a long-term staker, or stake just before an `evict` to capture most of the forfeit. Only verified entities with real tokens can do this. *Roadmap:* stream revenue over time or a minimum stake duration; the revocation watcher evicts atomically.
3. **Held revenue goes to the first stakers (Low).** Revenue that arrived with no stakers is released to whoever is staked when 10,000 tokens are first reached.
4. **Lazy eviction (Low).** Between a revocation and its `evict`, the revoked stake still dilutes others (returned to stakers at eviction). If the wallet is re-verified before anyone evicts it, it keeps what it accrued.
5. **Centralized verifier (High).** The contracts trust one verifier signature. *Roadmap:* multiple independent verifiers with threshold signatures; verifier rotation behind a timelock.
6. **Revocation latency (Medium).** A credential revoked *after* verification remains valid on-chain until `expiresAt` or `revokeWallet()` / `revokeEntity()`. In the demo, revocation is triggered manually to simulate a watcher detecting a TEL revocation. *Roadmap:* watcher service that pushes revocations on-chain and evicts automatically.
7. **Watcher integrity (Medium).** KEL/TEL checks depend on watcher data. *Roadmap:* query multiple watchers; reject on disagreement or detected duplicity.
8. **Undetected key compromise (Medium).** If KERI or wallet keys are stolen before rotation or revocation, the attacker is indistinguishable from the holder.
9. **Nominee activity (Medium).** A verified entity can act for an unverified party under an off-chain agreement. This needs legal controls, not code.
10. **Privileged roles (Medium).** The registry admin can revoke any wallet or entity; the Flap Guardian can upgrade every launcher and vault through their beacons. *Roadmap:* multisig + timelock for all admin actions.
11. **Funds sent by mistake are not recoverable (Low).** USDT or BNB transferred directly to a launcher or vault (outside `contribute` / the tax flow) has no rescue path; BNB sent to a USDT vault is ignored.
12. **Testnet stand-ins and price liveness (Low).** The quote is Flap's mock USDT, and the USDT path assumes 1 USDT = $1 with no depeg check. The v2 BNB factory uses real Atlas prices, but they reach the chain only when a relayer submits a fresh signed report (`scripts/push_atlas_price.py`, run every 30 min by `scripts/atlas_keeper.sh` in the demo); with no report for 1 hour BNB launches revert `StalePrice`. The v1 BNB factory keeps a `MockPriceFeed` (its feed is immutable).
13. **Factory enablement (Low on testnet).** The three launcher factories are enabled on the testnet Portal (Section 4.2); the vault factory is not yet, and on mainnet Flap enables factories only after an audit. The vault shows as unverified on Flap until audited.
14. **Launch can fail or not graduate (Low).** The Portal applies its own floors (creation 1,500 USDT, graduation 3,000 USDT on testnet). Below graduation the token launches but does not graduate; if the launch reverts, the sale fails safely and everyone can refund. The final contribution needs a high gas limit (`MIN_LAUNCH_GAS` = 7M).
15. **Unaudited code (Medium).** Written during a hackathon. Do not use with real funds.
16. **The Cournot decision is enforced off-chain (Low–Medium).** The probability gates *Contribute* in the KYB Portal (rate-risk acknowledgement), which can be bypassed by calling contracts directly. *Roadmap:* include the Cournot `requestId` and probability in the verifier-signed attestation and enforce a threshold on-chain.
17. **Privacy.** Only `keccak256(lei)` and role are stored, but anyone who knows an entity's LEI can link it to its wallets.
18. **Technical controls ≠ legal compliance.** Verifying identity and authority does not by itself make a token issuance or sale compliant with securities law in any jurisdiction.
19. **Sample credentials and simplified KERI plumbing (Medium for production).** The GLEIF root → QVI → LE → OOR/ECR chain is generated locally with keripy (`backend/scripts/make_test_chain.py`); it is not issued by GLEIF or a real QVI. Credentials are passed as a bundle: there is no witness network, OOBI resolution, KERIA/Signify agent or IPEX exchange yet. In the demo a backend agent signs the holder challenge on the holder's behalf; in production the holder signs from their own vLEI wallet.

---

## 9. CAS20 Alignment

This build gates the three things a Flap launch lets us control: who creates the launch (factory), who gets the first-round allocation (launcher) and who earns the tax yield (vault). Flap's Portal creates a standard tax token with no transfer hook, so **holding and trading are not gated**. BNB Chain's **CAS20 (BEP-702)** allowlist model fits that gap directly. CAS20 shipped with the Jenner hardfork on BSC Testnet, but token creation stays closed until BSC governance enables it. Once CAS20 issuance opens (and Flap can launch CAS20 tokens), the registry's `isActive` can back the token's allowlist so that every holder, not just contributors and stakers, is a verified legal entity.

---

## 10. Quick Start

### Prerequisites

- Node.js 20+ (npm)
- Python 3.12+ with `keripy`
- Foundry, jq
- BSC Testnet RPC + tBNB (a USDT launch needs only gas plus the 0.005 tBNB salt-lock fee)

### Environment

```bash
cp .env.example .env
# BSC_TESTNET_RPC_URL=        # fork tests, e2e and forge (BSC_TESTNET_RPC also accepted)
# DEPLOYER_PRIVATE_KEY=
# VERIFIER_PRIVATE_KEY=
# PINNED_ROOT_AID=
# WATCHER_URLS=
# CMC_API_KEY=
# COURNOT_API_KEY=            # optional: Cournot pack key; empty -> free quota (3 calls per IP)
# ATLAS_FEED_ADDRESS=         # empty -> MockPriceFeed (BNB path only)
# FLAP_PORTAL= / FLAP_GUARDIAN=   # defaults are the BSC Testnet addresses
# DEPLOYMENTS_FILE=           # e.g. ./deployments/97-fork.json on an anvil fork
```

### Contracts

```bash
cd contracts
forge build
forge test --no-match-path "test/fork/*"                        # 147 unit tests (98 v1 + 29 v2 + 20 AtlasSignedFeed), mock Portal
BSC_TESTNET_RPC_URL=https://bsc-testnet-rpc.publicnode.com \
  forge test --match-path "test/fork/*" -vv                     # 11 fork tests against the live Flap Portal (8 v1 + 3 USDT)
set -a; source ../.env; set +a
forge script script/Deploy.s.sol      --rpc-url $BSC_TESTNET_RPC_URL --broadcast   # v1 BNB          -> deployments/97.json
forge script script/DeployVault.s.sol --rpc-url $BSC_TESTNET_RPC_URL --broadcast   # v1 BNB + vault  -> deployments/97-vault.json
forge script script/DeployUsdt.s.sol  --rpc-url $BSC_TESTNET_RPC_URL --broadcast   # v2 USDT factories + vault pair -> deployments/97-usdt.json
```

Simulate each script without `--broadcast` first. `DeployUsdt.s.sol` reuses the registry from `deployments/97.json`.

### Full USDT journey on BSC Testnet

```bash
backend/.venv/bin/python scripts/testnet_full_usdt.py    # Section 3; resumable, finished steps are skipped
FULL_RPC=http://127.0.0.1:<anvil port> backend/.venv/bin/python scripts/testnet_full_usdt.py   # rehearse on a fork
```

It uses the funded keys in the repo-root `.env`, starts the backend on a temp copy of `backend/data`, simulates every write before sending, and logs to `logs/testnet/` (no keys).

### End-to-end on an anvil fork (v1, BNB)

```bash
BSC_TESTNET_RPC_URL=https://bsc-testnet-rpc.publicnode.com scripts/e2e_local.sh
```

Forks BSC Testnet, deploys to a temporary deployments file, enables the factory by impersonating the Portal admin (`contracts/script/enable_factory_fork.sh`), starts the backend on a copy of `backend/data`, and runs the BNB flow with `cast`.

### Test credentials

```bash
cd backend
python scripts/make_test_chain.py   # test root -> QVI -> LE -> OOR / ECR, plus a revoked set
```

### Backend

```bash
cd backend
pip install -r requirements.txt
ENABLE_DEMO_AGENT=true uvicorn app.main:app --reload --port 8000   # CHAIN_ID and RPC_URL must match the chain
```

### KYB Portal (frontend)

```bash
cd frontend
cp .env.local.example .env.local    # NEXT_PUBLIC_REGISTRY_ADDRESS, NEXT_PUBLIC_FACTORY_ADDRESS, NEXT_PUBLIC_PORTAL_ADDRESS
npm install
npm run sync-abis                   # after forge build
npm run dev
```

On an anvil fork (chainId 97) set `NEXT_PUBLIC_RPC_URL=http://127.0.0.1:8545` and the backend's `CHAIN_ID=97`, `RPC_URL=http://127.0.0.1:8545`.

### Flap launcher UI

```bash
cd flap-launcher-ui
./check.sh      # yarn launcher:check-source + typecheck + eslint, then zips all three components to dist/*.zip
```

---

## 11. Repository Structure

```text
.
├── contracts/                 # Foundry
│   ├── src/                   # v1: VLEIRegistry, VLEILauncherFactory, VLEIMintLauncher (BNB),
│   │   ├── vault/             #     VLEIVaultLauncherFactory + VLEIMintVaultLauncher + VLEIDividendVault(Factory)
│   │   └── v2/                # v2: shared launcher/factory bases, BNB-or-ERC20 quote (USDT), vault/ (VLEIDividendVaultV2)
│   ├── script/                # Deploy.s.sol, DeployVault.s.sol, DeployUsdt.s.sol, enable_factory_fork.sh
│   ├── deployments/           # 97.json (v1), 97-vault.json (v1 vault), 97-usdt.json (v2 USDT)
│   ├── test/                  # unit tests (mock Portal), test/v2, test/fork/*.fork.t.sol (live BSC Testnet Portal)
│   └── lib/FlapPoolLaunchVaultExample/   # Flap's LauncherFactoryBase, MintLauncher, vault bases, Portal interfaces
├── backend/                   # Verifier (keripy), Cournot + CMC endpoints, test-chain scripts
├── frontend/                  # vLEI KYB Portal: Next.js + viem (KYB, Intelligence, Launches, Admin)
├── flap-launcher-ui/          # Flap UI components (packaged ZIPs in dist/): vlei-gate-launcher,
│                              #   vlei-gate-vault-launcher, vlei-gate-vault; template/ = Flap's component template
├── scripts/                   # testnet_full_usdt.py, testnet_partial.py, e2e_local.sh / e2e_local.py
├── docs/                      # flow.md (detailed flows), demo-script.md, aws-production-plan.md, testnet-run.md (tx log), cmc-atlas-writeup.md, img/
└── logs/                      # cournot/ (raw Cournot logs), testnet/ (testnet run state + console logs)
```

---

## 12. Roadmap

- Pin GLEIF's production root AID and verify real vLEI credentials.
- Threshold verifier network; automated watcher-driven revocation and eviction.
- On-chain enforcement of Cournot risk thresholds.
- Vault: stream revenue over time or a minimum stake duration (removes timing games).
- Transfer-level gating with native CAS20 once issuance is enabled.
- Multisig + timelock for all admin functions; audit of launchers and vaults.
- **Production on AWS:** verifier signing key in AWS KMS (secp256k1), verifier and KERI witnesses / watchers / KERIA on ECS Fargate in three regions, watcher-driven revocation via EventBridge + Lambda, scheduled Atlas relayer, S3 Object Lock audit trail and Amazon Bedrock compliance briefs (advisory, never the decision). Plan and milestones: [`docs/aws-production-plan.md`](docs/aws-production-plan.md).

## License

MIT

## Team

`<names / handles>`
