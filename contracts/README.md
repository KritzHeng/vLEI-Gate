# vLEI-Gate contracts (Flap Pool Launch)

Foundry project (solc 0.8.26, cancun, `via_ir`, OpenZeppelin 5.1.0, solady 0.1.26) that runs a vLEI-gated contribution
round on **Flap's Pool Launch Portal**. Flap's Portal deploys the token itself (`launchTaxTokenV2` -> `FlapDirectTaxToken`)
and seeds the DEX pool, so the gate lives in our **Launcher Factory** and **Launcher**, not in the token.

| Contract | Purpose |
| --- | --- |
| `src/VLEIRegistry.sol` | Per-wallet vLEI result: `keccak256(lei)`, role (`ECR=1`, `OOR=2`, `OOR_OFFICER=3`), expiry. `register()` takes an EIP-712 `Attestation(wallet, leiHash, role, nonce, expiresAt)` signed by a `VERIFIER_ROLE` holder (domain `"vLEI-Gate Registry"`, `"1"`). The admin can `revokeEntity`, `revokeWallet` (bumps the nonce, so the wallet can be re-registered with a fresh attestation) and rotate verifiers. |
| `src/VLEILauncherFactory.sol` | Inherits Flap's `LauncherFactoryBase`. `_newLauncher` requires `registry.canLaunch(creator)` (OOR officer) and `quoteUsd(targetRaise) >= minTargetUsd`, then deploys a `VLEIMintLauncher` ERC1967 **beacon proxy** (salt `keccak256(creator, salt)`) and initializes it. The constructor deploys the Launcher implementation **bound to this factory**, so only this factory can initialize a proxy. `upgradeVaultImplementation` is Guardian-only. The owner can only set `maxPriceAge` and `minTargetUsd`. |
| `src/VLEIMintLauncher.sol` | Fork of Flap's `MintLauncher` with the same economics (1M supply, 50% pool / 50% pro-rata claim, 3%/5% tax, burn 10 / LP 15 / dividend 75, **no commission**, `commissionReceiver = address(0)`). Adds the vLEI gate: contributors must be active, the creator must still be active, and each **legal entity** (leiHash, across all its wallets) has a USD cap valued with the Atlas BNB/USD feed. Also adds `withdrawContribution()`, `cancelIfCreatorRevoked()`, and a gated `claim()`. |
| `src/interfaces/IPriceFeed.sol` | Aggregator interface used for the Atlas feed. |
| `src/oracle/AtlasSignedFeed.sol` | Atlas BNB/USD from signed Pull API reports: anyone relays `submit(payload, signature)`; the contract recovers the Atlas signer over `keccak256(payload)`, checks the feedId (633), rejects replays, rollbacks and future timestamps, and exposes an 8-dp aggregator feed. Deployed with `script/DeployAtlasFeed.s.sol`. |
| `src/mocks/MockPriceFeed.sol` | 8-dp feed deployed when `ATLAS_FEED_ADDRESS` is unset. Only its deployer can `setAnswer` to refresh it, and it goes stale after `maxPriceAge`. |
| `lib/FlapPoolLaunchVaultExample` | Flap's reference repo. `src/flap/*` (base contracts, Portal interface) is remapped as `src/flap/`. |

## Flow

```
creator (OOR officer) ── Portal.newLauncher{value: SALT_LOCK_FEE}(factory, abi.encode(VLEIMintConfig))
                          └─ factory.newLauncher(creator, data)   onlyHub
                               ├─ registry.canLaunch(creator)       else CreatorNotAuthorized(creator)
                               └─ beacon proxy -> initialize{fee}   launcher locks the salt itself
verified wallet ── launcher.contribute{value}   isActive(sender), isActive(creator), USD cap per leiHash
                   └─ the contribution that reaches targetRaise calls Portal.launchTaxTokenV2 (same tx)
verified wallet ── launcher.claim()             revoked -> NotVerified, tokens stay until re-verified
revoked wallet  ── launcher.withdrawContribution()  before launch only
anyone          ── launcher.cancelIfCreatorRevoked() -> everyone can refund() immediately
```

### `data` for `Portal.newLauncher(factory, data)`

`data = abi.encode(VLEIMintConfig)`, a single tuple:

```solidity
struct VLEIMintConfig {
    string  name;
    string  symbol;
    string  meta;            // metadata URI / IPFS CID
    bytes32 salt;            // token address CREATE2(0x7777c57f…2222, salt, Portal) must end in 0x7777
    uint256 targetRaise;     // wei; also the pool's quote side
    uint256 saleDuration;    // seconds, 1 .. 30 days
    uint256 capUsdPerEntity; // USD with 18 decimals, per legal entity
}
```

`msg.value` must equal `Portal.SALT_LOCK_FEE()` exactly (0.005 BNB on testnet). `factory.predictLauncher(creator, salt)` returns the launcher address in advance.
At creation `targetRaise` must be worth at least `factory.minTargetUsd()` (default **$1,600**, owner-settable) by the
BNB/USD feed; otherwise `TargetBelowMinimum(targetUsd, minTargetUsd)`. The live Portal rejects launches below its
liquidity floor (about $1,500 on testnet, error `0xa32ef056(quoteUsd, floorUsd)`), and such a sale could never launch.

### Launcher views for the Flap UI (no-arg or one `address`, never revert)

`status()` (0 Raising, 1 Launched, 2 Failed = deadline passed below target **or** the Portal rejected the launch, 3 Cancelled), `creatorActive()`, `bnbUsdPrice()` (USD×1e18, 0 if invalid or stale), `priceUpdatedAt()`, `vleiStatusOf(a)` (0 none, 1 active, 2 expired, 3 wallet revoked, 4 entity revoked), `vleiRoleOf(a)`, `vleiExpiresAt(a)`, `capUsdPerEntity()`, `token()`, `raised()`, `targetRaise()`, `saleDeadline()`, `creator()`, `contributionOf(a)`, `claimableOf(a)`, `remainingCapUsd(a)`.
Actions take no arguments: `contribute()` (payable), `claim()`, `refund()`, `withdrawContribution()`, `cancelIfCreatorRevoked()`.

### Rules

- `contribute()` accepts only what is still needed to reach the target. Any excess is returned in the same call
  (`ExcessRefunded`), so a front-run cannot make the final contribution revert. The creator must be
  `creatorActive()`: still an OOR officer **of the entity the sale was created for** (`creatorLei`).
- The target-reaching contribution launches. It needs at least `MIN_LAUNCH_GAS` (7M) left at that point
  (`InsufficientLaunchGas`), so a caller cannot force the launch to fail by out-of-gas. Wallets that estimate gas
  handle this automatically. If the Portal rejects the launch, the launcher emits `LaunchFailed(reason)`, sets
  `launchFailed`, reports `status() == 2`, and everyone (including the triggering contributor) can `refund()`
  immediately.
- `cancelIfCreatorRevoked()` (anyone): only when the creator's wallet or entity is **revoked**, the creator was
  re-registered under another LEI or without the officer role, or the creator's registration has been **expired for
  7 days** (`CREATOR_EXPIRY_GRACE`). A short lapse only pauses contributions.
- `withdrawContribution()`: only after an actual revocation (wallet or entity) or a move to another LEI. Expiry
  alone reverts `StillVerified`.
- `refund()`: after cancel, a rejected launch, or the deadline (at most 30 days) passed below target.

### Trust only `factory.isLauncher(addr)`

Anyone can deploy contracts that look like a `VLEIMintLauncher`, even with the same ABI and events. The Flap UI,
the KYB portal and indexers must treat an address as a vLEI launcher **only if `factory.isLauncher(addr)` is true**
(or it was emitted in the factory's `VLEILauncherCreated`). A proxy of our beacon deployed by someone else cannot be
initialized (`NotFactory`), but a copy of the code with another factory can.

## Enabling the factory (Flap)

Flap opens a factory with `Portal.setLauncherFactoryMultiplier(factory, multiplier, true)`. This is a **Portal admin**
call (DEFAULT_ADMIN / MANAGE / AUDITOR role, held by the ProxyAdmin owner `0x3bfC05a8…4a05` on testnet). The Flap
Guardian (`0x00004d58…0000`) has no Portal role; it is only the upgrade authority of our launchers.

On an anvil fork: `script/enable_factory_fork.sh [factory] [rpc]`. It impersonates the Portal admin.

Observed on BNB Testnet Portal v1.2.0 (fork tests 04/05): an **unopened** factory could still create **and** launch,
both with creation unpaused (the live state) and with creation paused. Enabling is still what Flap's track requires.
It also gives the factory its floor multiplier and the pause bypass, which matter on mainnet.

## Commands

```bash
forge build
forge test --no-match-path "test/fork/*"        # 147 unit tests: registry, v1/v2 launchers, vault, AtlasSignedFeed (mock Portal)

# Fork tests against the live BNB Testnet Portal (skipped without an RPC)
BSC_TESTNET_RPC_URL=https://bsc-testnet-rpc.publicnode.com \
  forge test --match-path "test/**/*.fork.t.sol" -vv   # BSC_TESTNET_RPC also accepted

# Deploy (writes deployments/<chainId>.json, or $DEPLOYMENTS_FILE)
set -a; source ../.env; set +a      # DEPLOYER_PRIVATE_KEY, VERIFIER_ADDRESS or VERIFIER_PRIVATE_KEY,
                                    # optional ADMIN_ADDRESS, ATLAS_FEED_ADDRESS, MAX_PRICE_AGE,
                                    # FLAP_PORTAL, FLAP_GUARDIAN, DEPLOYMENTS_FILE
forge script script/Deploy.s.sol --rpc-url $BSC_TESTNET_RPC --broadcast --verify

# Anvil fork of testnet (chainId 97): write elsewhere so deployments/97.json is not overwritten
anvil --fork-url $BSC_TESTNET_RPC &
DEPLOYMENTS_FILE=./deployments/97-fork.json forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
DEPLOYMENTS_FILE=./deployments/97-fork.json script/enable_factory_fork.sh
```

Deployment JSON keys: `chainId, registry, factory, launcherImpl, beacon, priceFeed, mockPriceFeed (bool), portal,
guardian, maxPriceAge, minTargetUsd (decimal string, 18 dp), admin, verifier`. `launcherImpl` is deployed by the factory. Run `forge script` from this directory, because the output path is relative.

## Limitations

- The Portal's token is a plain `FlapDirectTaxToken`. After the launch anyone can trade it. The gate covers the first-round
  investment and the claim, not secondary transfers.
- With `VLEIMintLauncher` the DIVIDEND tax share (75%) goes to Flap's dividend tracker for all holders. The
  gated-yield variant below (`VLEIMintVaultLauncher` + `VLEIDividendVault`) pays it only to verified stakers.
- Creator attestations last at most 30 days (registry TTL), and sales last at most 30 days. Plan to renew the creator's
  attestation before it lapses: while it is lapsed, contributions pause, and after 7 days anyone can cancel.

## Gated yield (new, additive): `VLEIMintVaultLauncher` + `VLEIDividendVault`

> Anyone can trade the token; first-round allocation **and yield** go only to verified legal entities.

A second Launcher + Vault pair, built on Flap's Crowd pattern. The original `VLEILauncherFactory` /
`VLEIMintLauncher` / `VLEIRegistry` are untouched and keep working; this pair is deployed next to them and reuses
the same registry and price feed.

| Contract | Purpose |
| --- | --- |
| `src/VLEIMintVaultLauncher.sol` | Copy of `VLEIMintLauncher` (same gate, caps, refunds, claims, same `VLEIMintConfig` payload). Only the tax split differs: **burn 10% / LP 15% / VAULT 75%** instead of DIVIDEND 75%. The VAULT slot names the paired vault factory with `vaultData = abi.encode(launcher)`. Adds `launching()` (public), `vaultFactory()`, `vault()` and `VaultAttached(token, vault)`. |
| `src/VLEIVaultLauncherFactory.sol` | Copy of `VLEILauncherFactory` (same `canLaunch` gate, USD minimum, Guardian-only upgrades). Extra constructor arg `vaultFactory`; reverts `VaultFactoryNotPaired` unless that factory's `launcherFactory()` is this factory. Event `VLEIVaultLauncherCreated`. |
| `src/vault/VLEIDividendVaultFactory.sol` | `DirectLaunchVaultFactoryBase` (`pl-v1`). `newVault` (onlyHub) accepts only a launcher the Portal recorded for the paired launcher factory, `vaultData` naming that launcher, native quote, VAULT slot exactly 7500 bps, `commissionReceiver == 0`, no reserve to the vault, and a launcher that is mid-launch with the full raise. Deploys one beacon proxy per token. Guardian-only `upgradeVaultImplementation`; no owner. |
| `src/vault/VLEIDividendVault.sol` | The gated vault (below). |
| `src/interfaces/IVLEIRegistryView.sol` | Registry getters used to tell revocation from expiry. |

### How tax reaches the vault (Flap mechanics, verified on the live testnet Portal)

```
contribute() reaching target ─► launcher._launch() ─► Portal.launchTaxTokenV2(p{feeConfigs: DEFLATION 1000, LP_BPS 1500,
                                                       VAULT 7500 {VLEIDividendVaultFactory, abi.encode(launcher)}}, ...)
   Portal ─► VLEIDividendVaultFactory.newVault(predictedToken, launcher, 0, abi.encode(p, dist))  ─► VLEIDividendVault proxy
   Portal ─► deploy token, seed + lock pool, initializeDistribution(reserved 50%) ─► launcher
DEX trades (anyone) ─► token tax ─► TaxProcessor.dispatch() ─► VLEIDividendVault.receive()   (native BNB, 75% of the tax)
```

### Vault rules

```
verified wallet ── vault.stake(amount)    isActive(sender); stake bound to its leiHash; min 1 token (approve first)
verified wallet ── vault.claim()          isActive and same leiHash; pays owed BNB
anyone          ── vault.unstake(amount)  principal never gated; if the caller is revoked: full exit + forfeit
anyone          ── vault.evict(account)   only if account is revoked / moved LEI / expired > 7 days:
                                          tokens returned to it, unclaimed BNB forfeited to the remaining stakers
TaxProcessor    ── receive()              balance-delta: accRewardPerShare += Δ·1e36 / totalStaked (storage only)
```

- **Pull-based, O(1) per call.** Dividends-per-share accumulator with per-staker checkpoint (`rewardDebt`, `owed`).
  No loops over holders, so any number of stakers is gas-safe. `receive()` makes no external call (~12k gas warm, through the proxy).
- **Why staking.** The token is Flap's `FlapDirectTaxToken`; we cannot hook its transfers. Staking gives the vault
  an exact earning balance per wallet and two natural gates: `isActive` at stake and at claim.
- **Revocation rule (chosen): forfeit and redistribute.** A revoked staker cannot claim. Anyone can `evict` it; its
  unclaimed rewards go pro rata to the remaining stakers (they have an incentive to evict). Expiry alone is not a
  revocation: an expired staker keeps earning, cannot claim until it renews, and its live stake becomes evictable
  7 days after expiry (same grace as the launcher's `CREATOR_EXPIRY_GRACE`). Rewards left after a full unstake are
  never forfeited by expiry alone, only by a revocation or an LEI move.
- **One LEI per position.** A position (stake or unclaimed rewards) is bound to the LEI it was staked under. A wallet
  re-registered under another LEI cannot stake or claim until the old position is evicted (forfeiting it), so rewards
  earned for one entity never leave through another.
- **Revenue with no stakers** (and forfeits when nobody is left) is held in `undistributed` and released only once at
  least `HELD_RELEASE_MIN_STAKE` (10,000 tokens, 1% of supply) is staked, so a single 1-token staker cannot sweep it.
- **No fee.** 100% of vault revenue goes to stakers; no creator/dev share; `commissionReceiver = 0` is enforced.
- Views: `stakedOf`, `pendingRewards`, `claimable`, `canClaim`, `evictable`, `isEarning`, `totalStaked`,
  `totalRevenue`, `totalClaimed`, `totalForfeited`, `undistributed`, `description()`, `vaultUISchema()`.

### Trade-offs

- Yield requires staking: holders who keep tokens in their wallet (including verified ones) earn nothing. Staked
  tokens are not in the wallet (cannot be sold without `unstake`).
- Revocation is enforced lazily. Between a revocation and its `evict`, the revoked stake still dilutes others; the
  diluted amount is returned to the remaining stakers on eviction (to the stakers at that time). If the wallet is
  re-verified before anyone evicts it, it keeps what it accrued. Mitigation: the revocation watcher calls `evict`
  for each staking wallet of the entity right after `revokeWallet` / `revokeEntity` (find them from `Staked` events).
- **Timing games are possible for verified holders.** `TaxProcessor.dispatch()` is permissionless and moving tokens
  into or out of the vault is not taxed (checked on the live Portal), so a verified holder can stake, dispatch, claim
  and unstake in one transaction and earn the same share as a long-term staker. Likewise, staking right before an
  `evict` captures most of the forfeited rewards. Only verified entities with real tokens can do this, and the
  watcher evicting atomically with the revocation removes the second case. Roadmap: stream revenue over time
  (reward rate) or a minimum stake duration.
- Once `HELD_RELEASE_MIN_STAKE` is reached, held revenue goes to whoever is staked at that moment.
- Up to 1 wei per staker of rounding; `claim` never pays from held revenue (a shortfall stays owed).

### What Flap must enable / audit

- `Portal.setLauncherFactoryMultiplier(VLEIVaultLauncherFactory, m, true)` (required for creation when paused).
- `Portal.setVaultFactoryMultiplier(VLEIDividendVaultFactory, m, true)` (liquidity-floor multiplier + low-risk badge;
  since Portal v1.1.2 the launch itself is covered by the launcher factory alone).
- Audit both factories (the vault shows as UNVERIFIED on Flap.sh until then). Upgrades: Guardian only, both beacons.

### Commands

```bash
forge test --match-path test/VLEIDividendVault.t.sol                       # 22 unit tests (mock Portal with VAULT slot)
BSC_TESTNET_RPC_URL=https://bsc-testnet-rpc.publicnode.com \
  forge test --match-path test/fork/VLEIDividendVault.BSCTest.fork.t.sol -vv  # live Portal: launch, trades, claim, revoke

# Deploy next to deployments/<chainId>.json (reuses its registry + priceFeed). Simulate first:
forge script script/DeployVault.s.sol --rpc-url $BSC_TESTNET_RPC
# then add --broadcast; writes ./deployments/<chainId>-vault.json (only when broadcasting)
```

## v2: ERC20 quote (USDT) and native BNB from one codebase

The v1 contracts above are **unchanged**: their deployed testnet bytecode (factories `0x2791…Eb3b`,
`0x3fF9…c1c6`, `0x3A79…c548` and their implementations) is reproduced exactly by the current sources (metadata hashes
match). The shared refactor therefore lives in new, versioned contracts under `src/v2/`. Deploy them for USDT launches
(or, with `quoteToken = address(0)`, for new BNB launches with the same behaviour as v1).

| Contract | Purpose |
| --- | --- |
| `src/v2/VLEILauncherBaseV2.sol` | Abstract round shared by both launchers: gate, caps, refunds, cancel, withdraw, claim, try/catch launch with `LaunchFailed`, `MIN_LAUNCH_GAS`, creator expiry grace, 30-day max duration. Variants override only `_feeConfigs`, `_texts`, `_initVariant`, `_afterLaunch`. |
| `src/v2/VLEIMintLauncherV2.sol` | Burn 10 / LP 15 / DIVIDEND 75 (`dividendToken = 0` = the quote, so USDT dividends for a USDT launch). |
| `src/v2/VLEIMintVaultLauncherV2.sol` | Burn 10 / LP 15 / VAULT 75 → `VLEIDividendVaultV2`. `vaultFactory()`, `vault()`, `VaultAttached`. |
| `src/v2/VLEILauncherFactoryBaseV2.sol` | Abstract factory shared by both: `canLaunch` gate, `minTargetUsd` at creation, beacon proxies bound to the factory, Guardian-only upgrades. **Immutable `quoteToken`** (`address(0)` = BNB). |
| `src/v2/VLEILauncherFactoryV2.sol`, `src/v2/VLEIVaultLauncherFactoryV2.sol` | Concrete factories (events `VLEILauncherCreated` / `VLEIVaultLauncherCreated`, unchanged). The vault one also checks the paired vault factory's `quoteToken()` (`VaultQuoteMismatch`). |
| `src/v2/vault/VLEIDividendVaultV2.sol`, `src/v2/vault/VLEIDividendVaultFactoryV2.sol` | The gated vault with revenue in the launch quote. The factory has an immutable `quoteToken`; `isQuoteTokenSupported(q)` is `q == quoteToken`; `newVault` also requires `p.quoteToken == quoteToken`. |

`data` for `Portal.newLauncher` is the same `abi.encode(VLEIMintConfig)` tuple; `targetRaise` is in quote wei.

### Quote rules

| | Native (`quoteToken == 0`) | ERC20 (e.g. mock USDT `0x190C…0157`) |
| --- | --- | --- |
| Factory | `priceFeed` required; `minTargetUsd` default $1,600 | `priceFeed` must be `0` (`PriceFeedNotUsed`); quote must have 18 decimals (`UnsupportedQuoteDecimals`); `minTargetUsd` default **1,500** |
| USD valuation | amount × Atlas BNB/USD (staleness-checked) | **1:1**: 1 quote token = $1, no feed, no Portal read. `capUsdPerEntity`, `investedUsd`, `remainingCapUsd`, `minTargetUsd` are all in quote units |
| `contribute()` | payable; excess over the target is sent back | `msg.value` must be 0 (`UnexpectedNativeValue`). Pulls **min(allowance, balance, target − raised, entity cap left)**. Reverts `EntityCapReached`, `NoAllowance`, `NoQuoteBalance` when that is 0 |
| `contributeAmount(uint256)` | reverts `NativeQuote` | pulls exactly `amount` (clamped to target − raised); over the cap → `CapExceeded`. For the KYB portal and scripts |
| Crediting | `msg.value` | balance delta of the launcher (fee-on-transfer safe; more than requested → `QuoteTransferMismatch`) |
| Launch | `launchTaxTokenV2{value: poolQuote}` | `forceApprove(Portal, poolQuote)`, `launchTaxTokenV2{value: 0}`, allowance reset to 0 after success **or** failure |
| Refund / withdraw | BNB | the quote token (`SafeERC20`) |
| `bnbUsdPrice()` | Atlas price (0 if stale) | always `1e18` (= `ERC20_QUOTE_USD`: USD per quote unit) |
| `priceUpdatedAt()` | feed timestamp | `block.timestamp` (fixed price, never stale) |
| `allowanceOf(a)` | `type(uint256).max` (no approval needed) | `allowance(a, launcher)` |
| `quoteBalanceOf(a)` | `a.balance` | `balanceOf(a)` |

The 16 UI views and 5 no-arg actions keep their names and meaning. New views: `quoteToken()`, `allowanceOf(address)`,
`quoteBalanceOf(address)`, `previewContribute(address)` (what a no-arg `contribute()` pulls now), `launching()`.
`maxContribution(address)` is the cap/target bound only (the amount to approve).

**UI flow for an ERC20 launcher** (the Flap UI cannot approve): show `quoteToken()`; if `allowanceOf(user) == 0`, tell
the user to approve the launcher on the quote token for up to `maxContribution(user)` (e.g. from a wallet or the KYB
portal); then `contribute()` with value 0.

### Vault revenue in USDT

The TaxProcessor transfers USDT to the vault and then wakes it with a zero-value call to `receive()`, which runs
`_sync()` (balance delta on `IERC20(quoteToken).balanceOf(vault)`). `sync()` is public, and `stake`, `unstake`,
`claim` and `evict` all sync first, so revenue is never lost if a wake is missed. BNB sent to a USDT vault is ignored
(not revenue; `receive()` never reverts). All v1 vault rules are unchanged (`HELD_RELEASE_MIN_STAKE`, LEI binding of
owed positions, expiry semantics, pull-before-settle, claimable cap); claims pay USDT.

### Portal numbers (BNB Testnet, Portal v1.2.0, read on chain)

- `launchQuoteConfig(0, USDT) = (true, 1e18)`; `launchQuoteConfig(0, 0x0) = (true, 700e18)`.
- `graduationFloorV2` / `graduationFloorV2ForLauncher` for 1M supply, 500k pool token, multiplier 10000:
  **creation floor $1,500** (1,500 USDT), **graduation floor $3,000** (3,000 USDT). 1,499 USDT → `meetsCreateFloor =
  false` (`LaunchLiquidityTooLow`); 1,500–2,999 → launches but not graduated; ≥ 3,000 → `FlapTokenGraduated`.
- Unopened factories launch fine (the USDT fork tests never call `setLauncherFactoryMultiplier` /
  `setVaultFactoryMultiplier`), so a USDT launch needs only gas plus the 0.005 BNB salt-lock fee. A final
  `contribute()` that launches uses about 4.9M gas, under `MIN_LAUNCH_GAS` (7M).

### Commands

```bash
forge test --no-match-path "test/fork/*"                       # 127 unit tests (98 v1 + 29 v2)
BSC_TESTNET_RPC_URL=https://bsc-testnet-rpc.publicnode.com \
  forge test --match-path "test/fork/*" -vv                    # 11 fork tests (8 v1 + 3 USDT v2)

# Deploy the USDT factories (plain + vault pair) next to the live registry 0x7210…89EF. Simulate first:
forge script script/DeployUsdt.s.sol --rpc-url $BSC_TESTNET_RPC
# then add --broadcast; writes ./deployments/<chainId>-usdt.json (only when broadcasting)
```
