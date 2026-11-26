# Atlas signed payload: format and signature scheme

How `contracts/src/oracle/AtlasSignedFeed.sol` and `scripts/push_atlas_price.py` read a signed report from the Atlas Oracle
Pull API (`POST https://api.atlasoracle.io/report/v1/price/latest`, body `{"feedIds":["<id>"],"signed":true}`). Source:
the Atlas Oracle *Pull API and WebSocket* integration guide provided to hackathon teams.

## Evidence

The Atlas docs publish three real `payload` / `signature` / `parsedPayload` triples (latest, history, WebSocket push),
all for feedId `624` (a ~$1.00 asset, not BNB). They are replayed in `contracts/test/AtlasSignedFeed.t.sol`
(`test_docExamplesRecoverAtlasSigner_rawKeccak`, `test_docExamplesDecode`) and were cross-checked in Python
(`eth_account`) before writing the contract.

| Example | payload | v | parsed price | parsed timestamp |
| --- | --- | --- | --- | --- |
| latest | `0x00000270 00000de01dedfc23734f 00006a27cdd3 01` | 27 | 999832025250886479 | 1780993491 |
| WebSocket | `0x00000270 00000ddff9a9ef12d28d 00006a27d82d 01` | 27 | 999792150555316877 | 1780996141 |
| history | `0x00000270 00000ddecb3a6f7ee607 00006a6aef1e 01` | 28 | 999459619161957895 | 1785392926 |

(spaces added at the field boundaries)

## Payload layout (21 bytes for one feed)

Big-endian, tightly packed:

| Offset | Size | Field | Example |
| --- | --- | --- | --- |
| 0 | 4 | `feedId` (uint32) | `0x00000270` = 624 |
| 4 | 10 | `price` (uint80, 1e18 scale) | `0x00000de01dedfc23734f` = 999832025250886479 |
| 14 | 6 | `timestampSeconds` (uint48) | `0x00006a27cdd3` = 1780993491 |
| 20 | 1 | entry count | `0x01` |

The field widths match Atlas' own on-chain `FeedCodec` library
([oracle-atlas/push-oracle-interfaces](https://github.com/oracle-atlas/push-oracle-interfaces): `bytes4 feedId`,
`uint80` price, `uint48` timestamp). Every value decodes exactly to the `parsedPayload` JSON.

**Assumption (not provable from the examples):** the trailing byte is the number of entries, so a multi-feed report
(`feedIds` with several ids) is `N × 20-byte entries ‖ uint8 N`. All published examples have N = 1, so the byte could
also be a version tag. The contract therefore requires `length == 20·N + 1` **and** `lastByte == N`: single-feed
reports (the only kind we request) always pass, and an unexpected format fails closed (`MalformedPayload`) instead of
being misread. Request one feedId per call to stay on the verified path.

## Signature scheme

- Message hash: `keccak256(payloadBytes)`, i.e. keccak over the **raw decoded payload bytes**, with **no** EIP-191
  `"\x19Ethereum Signed Message:\n"` prefix. (The doc's wording "Keccak256 hash of the payload hex string" means the hex
  decoded to bytes; its Java example calls `Hash.sha3(hexStringToByteArray(payload))`.)
- Signature: 65 bytes `r ‖ s ‖ v`, `v ∈ {27, 28}`, low-`s` (all three examples), so OpenZeppelin `ECDSA.recover`
  accepts them as-is and rejects malleable high-`s` variants.
- Signer: `0x59ed4701224fd9e2a85ef2946c2ab828c1ddc600` (recovered from all three examples).

Alternatives tested and rejected (each recovers a different, random address): EIP-191 over the payload bytes,
keccak over the ASCII hex string.

## `magicMarker` (`0x7096`)

Not part of the signed bytes (the signature recovers over `payload` alone) and not inside the payload. The docs call
it a fixed "Atlas Oracle identifier". It is presumably appended to calldata by Atlas' own push contracts; our feed
does not need it. `push_atlas_price.py` only checks that it equals `0x7096` when present.

## How AtlasSignedFeed uses it

`submit(payload, signature)` (permissionless): recover signer == `atlasSigner` → find the entry for `feedId` →
price > 0 → timestamp strictly newer than the stored one (no replay / rollback) and ≤ `block.timestamp + 60` → store.
`latestRoundData()` returns `answer = price / 1e10` (8 decimals, like the MockPriceFeed and Chainlink BNB/USD) and
`updatedAt = timestampSeconds` (age of the Atlas observation, which the factory checks against `maxPriceAge`). The raw
1e18 value is in `latestRawPrice()`.

Known properties (see the review tests in `AtlasSignedFeed.t.sol`): any signed report newer than the stored one is
accepted, including an older one from `/v1/price/history`, so a relayer can choose which observation inside the
factory's `maxPriceAge` window (1 h) becomes the price, bounded by BNB's move over that window. A report up to 60 s
ahead of the chain clock is stored, but consumers revert `StalePrice` on `updatedAt > block.timestamp` until the chain
catches up.
