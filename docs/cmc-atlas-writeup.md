# CoinMarketCap × Atlas in vLEI-Gate

vLEI-Gate lets only GLEIF-vLEI-verified legal entities create and invest in tokenized RWA launches on BNB Chain (Flap Pool Launch). Native-BNB launches need a USD view of BNB: the minimum raise and each legal entity's investment cap are set in dollars. **Atlas** provides that price on-chain, with its signature verified by our contract. **CoinMarketCap** independently cross-checks Atlas before a price reaches the chain and before an investor can contribute. Both feed core decisions; neither is only displayed.

## 1. Atlas: signed prices verified on-chain

- **Source:** Atlas Pull API `POST https://api.atlasoracle.io/report/v1/price/latest` with `{"feedIds": ["633"], "signed": true}`. feedId **633** is BNB/USD. We confirmed it against Atlas' public `bnb/usd` push feed on BSC mainnet (`0x9c05…6438`): the values matched exactly on 12 of 12 consecutive updates.
- **Relayer** (`scripts/push_atlas_price.py`, run every 30 min by `scripts/atlas_keeper.sh`): it requires `consensusStatus = HEALTHY`, a report under 5 min old, a valid Atlas signature off-chain, and agreement with CMC (§2). It then calls `submit(payload, signature)`.
- **Contract `AtlasSignedFeed`** (`0x34aa570cDa23282af94aA3CE4232bD4B18B644d5`, BSC Testnet, verified):
  - It trusts no relayer. It recovers the signer over `keccak256(payload)` and accepts only the Atlas signer `0x59eD…C600`.
  - It decodes `feedId | price | timestamp`, requires feedId 633, and rejects replays, rollbacks and timestamps more than 60 s in the future.
  - It exposes a standard aggregator interface (`latestRoundData`, 8 decimals).
- **Enforcement:** `VLEILauncherFactoryV2` (`0x394928211B03Eb74a6f7061a56973F77A7fC48a4`) and its launchers value BNB with this feed. A price older than 1 h reverts with `StalePrice`, so the system fails safe. The feed is used in two places:
  - **Creating a launch:** the target must be worth at least `minTargetUsd` ($1,600).
  - **Contributing:** the BNB amount is converted to USD and counted against the **per-legal-entity** cap, shared by all wallets of the same vLEI entity.

**Proof on BSC Testnet (2026-11-26, Atlas price $559.97):**

| Action | Result | Tx |
| --- | --- | --- |
| New launch with a 1 BNB target (~$560 < $1,600) | reverted `TargetBelowMinimum` | `0xfa6fcbaf…5d351a5c` |
| New launch with a 3.2 BNB target ($1,791.90), cap $10 per entity | launcher `0x206dB9B3…609b` | `0x567695e6…a1e2344e` |
| Contribute 0.01 BNB (~$5.60) | success, $4.40 of the cap left | `0x9a47c34c…8d8d7a8d` |
| Contribute 0.01 BNB again (~$11.20 total > $10) | reverted `CapExceeded` | `0x0ac3a496…eb19a980` |

## 2. CoinMarketCap: an independent check in two places

The backend calls CMC Pro `GET /v1/cryptocurrency/quotes/latest` (BNB/USD). The key stays server-side and results are cached for 60 s.

1. **Before a price goes on-chain.** The relayer refuses to submit an Atlas report that differs from CMC by more than **2%** (`--max-deviation-bps 200`). If CMC is unreachable it also refuses, so the check fails closed.
2. **Before an investor contributes.** `GET /api/market/price-check` compares the on-chain Atlas price with CMC and returns `ok`, `deviation`, `stale` or `unavailable`. On Atlas-priced BNB launches the KYB Portal disables *Contribute* unless the status is `ok`, and it shows both prices and the deviation.

At the time of writing, Atlas was $559.97 and CMC $560.25, a deviation of 0.05% (status `ok`).

## 3. Where users see it

- **`/verify` → Risk & market intelligence:** Atlas (signed, on-chain) next to CMC, with the deviation and freshness.
- **`/offerings/<launcher>`:** the "Price check passed / failed" line under *Contribute*, and the reason when contributions are paused.

## 4. Safety

| Risk | Control |
| --- | --- |
| Forged or replayed price | On-chain Atlas signature check, feedId check, replay and rollback rejection |
| Stale price | 1 h `maxPriceAge` on-chain (reverts `StalePrice`); 5 min freshness at relay time |
| Bad consensus | Atlas `consensusStatus` must be `HEALTHY` |
| A wrong or manipulated Atlas value | The CMC deviation check at relay time and before contributing |
| A source that is down | Fail closed: no relay and no contribution |

## Limitations

- Prices reach the chain only when a relayer submits a fresh report. Anyone can relay, but someone has to.
- The CMC check runs off-chain, in the relayer and the KYB Portal. A direct contract call is still bounded by Atlas, but not by CMC.
- On the USDT path 1 USDT counts as $1; no feed is used and there is no depeg check.
- The older v1 BNB factory keeps a `MockPriceFeed`, because its feed address is immutable. The Atlas path is the v2 factory above.
- BSC Testnet only; the code is not audited.
