#!/usr/bin/env python3
"""Relay a signed Atlas Oracle price report to the on-chain AtlasSignedFeed (BSC testnet).

    backend/.venv/bin/python scripts/push_atlas_price.py [--dry-run] [--set-feed-id] [--max-age 300]
    backend/.venv/bin/python scripts/push_atlas_price.py --from-json saved_response.json   # offline report

Steps:
  1. POST https://api.atlasoracle.io/report/v1/price/latest  {"feedIds": [ATLAS_BNB_FEED_ID], "signed": true}
     with header X-API-KEY: ATLAS_API_KEY (never printed).
  2. Checks: status.error_code == "0"; consensusStatus == HEALTHY (DEGRADED only with --allow-degraded);
     payload decodes (docs/atlas-payload-format.md) to an entry for the feed with a non-zero price; the
     signature over keccak256(payload) recovers to the feed's on-chain atlasSigner(); the price timestamp is at
     most --max-age seconds old, not more than 60 s in the future (FUTURE_SKEW, as in the contract), newer than the
     on-chain one, and within --max-deviation-bps (default 200) of the CoinMarketCap BNB price.
  3. eth_call simulation, then sends AtlasSignedFeed.submit(payload, signature) from DEPLOYER_PRIVATE_KEY
     (submit is permissionless; any funded key works).

  --set-feed-id: if the on-chain feedId() is still 0, first call setFeedId(ATLAS_BNB_FEED_ID) from the owner key
  (ADMIN_PRIVATE_KEY, else DEPLOYER_PRIVATE_KEY). Only possible before the first successful submit.

Env (repo-root .env; shell values take precedence):
  ATLAS_API_KEY              SECRET, required unless --from-json
  ATLAS_BNB_FEED_ID          Atlas feedId of BNB/USD (required)
  ATLAS_SIGNED_FEED_ADDRESS  default: contracts/deployments/<CHAIN_ID>-atlas.json .atlasSignedFeed
  RPC_URL                    default: BSC_TESTNET_RPC / BSC_TESTNET_RPC_URL
  DEPLOYER_PRIVATE_KEY       SECRET, relayer key
  ADMIN_PRIVATE_KEY          SECRET, optional, owner key for --set-feed-id
Keys are only used in-process to sign; they are never printed or logged.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path

import httpx
from dotenv import dotenv_values
from eth_abi import decode as abi_decode
from eth_abi import encode as abi_encode
from eth_account import Account
from eth_utils import keccak, to_checksum_address

ROOT = Path(__file__).resolve().parent.parent
ATLAS_URL = "https://api.atlasoracle.io/report/v1/price/latest"
ENTRY_LEN = 20  # feedId uint32 | price uint80 | timestampSeconds uint48
FUTURE_SKEW = 60  # same as AtlasSignedFeed.MAX_FUTURE_SKEW
BNB_USD_SANE = (50, 10_000)  # plausibility bounds (USD) before --set-feed-id locks an id


def die(msg: str, code: int = 1) -> None:
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(code)


def load_env() -> dict[str, str]:
    env = {k: v for k, v in dotenv_values(ROOT / ".env").items() if v is not None}
    env.update({k: v for k, v in os.environ.items()})
    return {k: v.strip() for k, v in env.items() if v is not None and v.strip() != ""}


def sel(sig: str) -> bytes:
    return keccak(text=sig)[:4]


class Rpc:
    def __init__(self, url: str) -> None:
        self.url = url
        self.http = httpx.Client(timeout=30)
        self._id = 0

    def __call__(self, method: str, params: list):
        self._id += 1
        r = self.http.post(self.url, json={"jsonrpc": "2.0", "id": self._id, "method": method, "params": params})
        if r.status_code != 200:  # never echo the URL: hosted RPC URLs often embed an API key
            raise RuntimeError(f"{method}: RPC returned HTTP {r.status_code}")
        body = r.json()
        if "error" in body:
            raise RuntimeError(f"{method}: {body['error']}")
        return body["result"]

    def call(self, to: str, data: bytes, sender: str | None = None) -> bytes:
        tx = {"to": to, "data": "0x" + data.hex()}
        if sender:
            tx["from"] = sender
        return bytes.fromhex(self("eth_call", [tx, "latest"])[2:])


def fetch_cmc_bnb(env: dict) -> float:
    """BNB/USD from CoinMarketCap (/v1/cryptocurrency/quotes/latest). Fails closed: no CMC, no push."""
    key = env.get("CMC_API_KEY")
    if not key:
        die("CMC_API_KEY is not set (needed for the Atlas/CMC cross-check; --skip-cmc-check to bypass)")
    base = env.get("CMC_BASE_URL") or "https://pro-api.coinmarketcap.com"
    try:
        r = httpx.get(f"{base}/v1/cryptocurrency/quotes/latest", params={"symbol": "BNB", "convert": "USD"},
                      headers={"X-CMC_PRO_API_KEY": key, "Accept": "application/json"}, timeout=15)
        r.raise_for_status()
        entry = r.json()["data"]["BNB"]
        entry = entry[0] if isinstance(entry, list) else entry
        p = float(entry["quote"]["USD"]["price"])
    except Exception as e:  # noqa: BLE001 - any failure means we cannot cross-check
        die(f"CoinMarketCap cross-check failed: {type(e).__name__}")
    if p <= 0:
        die("CoinMarketCap returned a non-positive BNB price")
    return p


def decode_payload(payload: bytes, feed_id: int) -> tuple[int, int]:
    n_len = len(payload)
    if n_len < ENTRY_LEN + 1 or (n_len - 1) % ENTRY_LEN:
        raise ValueError(f"malformed payload length {n_len}")
    n = (n_len - 1) // ENTRY_LEN
    if payload[-1] != n:
        raise ValueError(f"payload count byte {payload[-1]} != {n} entries")
    for i in range(n):
        e = payload[i * ENTRY_LEN:(i + 1) * ENTRY_LEN]
        if int.from_bytes(e[0:4], "big") == feed_id:
            return int.from_bytes(e[4:14], "big"), int.from_bytes(e[14:20], "big")
    raise ValueError(f"feedId {feed_id} not in payload")


def fetch_report(api_key: str, feed_id: int) -> dict:
    try:
        r = httpx.post(
            ATLAS_URL,
            headers={"X-API-KEY": api_key, "Content-Type": "application/json"},
            json={"feedIds": [str(feed_id)], "signed": True},
            timeout=20,
        )
    except httpx.HTTPError as e:
        die(f"Atlas request failed: {type(e).__name__}")
    try:
        body = r.json()
    except ValueError:
        die(f"Atlas returned HTTP {r.status_code} with a non-JSON body")
    status = body.get("status") or {}
    if r.status_code != 200 or str(status.get("error_code")) != "0":
        die(f"Atlas error (HTTP {r.status_code}): {status.get('error_code')} {status.get('error_message')}")
    return body


def send_tx(rpc: Rpc, acct, to: str, data: bytes, chain_id: int, label: str) -> str:
    sender = acct.address
    tx = {"from": sender, "to": to, "data": "0x" + data.hex()}
    gas = int(rpc("eth_estimateGas", [tx, "latest"]), 16)
    gas_price = int(rpc("eth_gasPrice", []), 16)
    nonce = int(rpc("eth_getTransactionCount", [sender, "pending"]), 16)
    signed = acct.sign_transaction(
        {
            "to": to_checksum_address(to),
            "data": data,
            "value": 0,
            "gas": gas * 12 // 10,
            "gasPrice": gas_price,
            "nonce": nonce,
            "chainId": chain_id,
        }
    )
    raw = getattr(signed, "raw_transaction", None) or signed.rawTransaction
    tx_hash = rpc("eth_sendRawTransaction", ["0x" + raw.hex().removeprefix("0x")])
    print(f"{label}: sent {tx_hash}")
    for _ in range(60):
        rcpt = rpc("eth_getTransactionReceipt", [tx_hash])
        if rcpt:
            if int(rcpt["status"], 16) != 1:
                die(f"{label}: reverted ({tx_hash})")
            print(f"{label}: mined in block {int(rcpt['blockNumber'], 16)}, gas {int(rcpt['gasUsed'], 16)}")
            return tx_hash
        time.sleep(2)
    die(f"{label}: no receipt after 120 s ({tx_hash})")
    return tx_hash


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dry-run", action="store_true", help="fetch, verify and simulate; do not send")
    ap.add_argument("--set-feed-id", action="store_true", help="set the on-chain feedId first if it is still 0")
    ap.add_argument("--max-age", type=int, default=300, help="max age of the Atlas price in seconds (default 300)")
    ap.add_argument("--allow-degraded", action="store_true", help="also accept consensusStatus DEGRADED")
    ap.add_argument("--max-deviation-bps", type=int, default=200,
                    help="refuse to push if Atlas and CoinMarketCap disagree by more than this (default 200 = 2%%)")
    ap.add_argument("--skip-cmc-check", action="store_true", help="do not cross-check the Atlas price with CoinMarketCap")
    ap.add_argument("--from-json", help="use a saved Atlas response (full body or its .data) instead of calling the API")
    args = ap.parse_args()

    env = load_env()
    if not args.from_json and not env.get("ATLAS_API_KEY"):
        die(
            "ATLAS_API_KEY is not set. Create an account on the Atlas website to get an API key, put it in the "
            "repo-root .env as ATLAS_API_KEY=..., and run again. (Nothing was sent.)"
        )
    feed_id_s = env.get("ATLAS_BNB_FEED_ID")
    if not feed_id_s:
        die("ATLAS_BNB_FEED_ID is not set in .env (the Atlas feedId of BNB/USD, e.g. from your Atlas dashboard).")
    try:
        feed_id = int(feed_id_s)
    except ValueError:
        die(f"ATLAS_BNB_FEED_ID must be an integer, got {feed_id_s!r}")
    if not 0 < feed_id <= 0xFFFFFFFF:
        die("ATLAS_BNB_FEED_ID must be in 1..2^32-1 (uint32)")

    chain_id = int(env.get("CHAIN_ID", "97"))
    rpc_url = env.get("RPC_URL") or env.get("BSC_TESTNET_RPC") or env.get("BSC_TESTNET_RPC_URL")
    if not rpc_url:
        die("RPC_URL is not set")
    feed_addr = env.get("ATLAS_SIGNED_FEED_ADDRESS")
    if not feed_addr:
        dep = ROOT / "contracts" / "deployments" / f"{chain_id}-atlas.json"
        if not dep.exists():
            die(f"ATLAS_SIGNED_FEED_ADDRESS not set and {dep} not found")
        feed_addr = json.loads(dep.read_text())["atlasSignedFeed"]
    feed_addr = to_checksum_address(feed_addr)
    rpc = Rpc(rpc_url)
    if int(rpc("eth_chainId", []), 16) != chain_id:
        die(f"RPC chainId != CHAIN_ID {chain_id}")

    # ── report ──
    if args.from_json:
        body = json.loads(Path(args.from_json).read_text())
        if "status" in body and str(body["status"].get("error_code")) != "0":
            die(f"saved response is an error: {body['status']}")
    else:
        body = fetch_report(env["ATLAS_API_KEY"], feed_id)
    data = body.get("data", body)
    if not data or not data.get("payload") or not data.get("signature"):
        die("Atlas response has no signed payload (was signed=true honoured?)")
    if data.get("magicMarker") and data["magicMarker"].lower() != "0x7096":
        die(f"unexpected magicMarker {data['magicMarker']}")
    scores = {str(s.get("feedId")): s for s in data.get("consensusScores") or []}
    score = scores.get(str(feed_id))
    if score is None:
        if not args.from_json:
            die("no consensusScores entry for the feed")
        print("warning: no consensusScores in the saved response")
    else:
        status = score.get("consensusStatus")
        ok = {"HEALTHY"} | ({"DEGRADED"} if args.allow_degraded else set())
        print(f"consensus: {status} (score {score.get('consensusScore')})")
        if status not in ok:
            die(f"consensusStatus {status} not accepted; refusing to push")

    payload = bytes.fromhex(data["payload"].removeprefix("0x"))
    signature = bytes.fromhex(data["signature"].removeprefix("0x"))
    price, ts = decode_payload(payload, feed_id)
    if price == 0:
        die("price is zero")
    now = int(time.time())
    print(f"report: feedId {feed_id} price {price / 1e18:.8f} USD ts {ts} ({now - ts} s old)")
    if ts > now + FUTURE_SKEW:
        die("price timestamp is in the future")
    if now - ts > args.max_age:
        die(f"price is {now - ts} s old (> --max-age {args.max_age}); refusing to push")

    # ── independent cross-check: CoinMarketCap must agree with Atlas before the price goes on-chain ──
    if args.skip_cmc_check:
        print("warning: CoinMarketCap cross-check skipped (--skip-cmc-check)")
    else:
        cmc_price = fetch_cmc_bnb(env)
        dev_bps = abs(price / 1e18 - cmc_price) / cmc_price * 10_000
        print(f"cmc cross-check: CoinMarketCap {cmc_price:.4f} USD, deviation {dev_bps:.1f} bps "
              f"(max {args.max_deviation_bps})")
        if dev_bps > args.max_deviation_bps:
            die(f"Atlas and CoinMarketCap disagree by {dev_bps:.1f} bps (> {args.max_deviation_bps}); refusing to push")

    # ── on-chain state ──
    (signer,) = abi_decode(["address"], rpc.call(feed_addr, sel("atlasSigner()")))
    (onchain_feed,) = abi_decode(["uint32"], rpc.call(feed_addr, sel("feedId()")))
    _, _, _, updated_at, _ = abi_decode(
        ["uint80", "int256", "uint256", "uint256", "uint80"], rpc.call(feed_addr, sel("latestRoundData()"))
    )
    recovered = Account._recover_hash(keccak(payload), signature=signature)
    print(f"feed {feed_addr}: feedId {onchain_feed}, atlasSigner {signer}, last update {updated_at}")
    if recovered.lower() != signer.lower():
        die(f"signature recovers to {recovered}, not the feed's atlasSigner {signer}")
    if ts <= updated_at:
        print(f"on-chain price (ts {updated_at}) is already as new as this report; nothing to do")
        return

    pk = env.get("DEPLOYER_PRIVATE_KEY")
    if not pk:
        die("DEPLOYER_PRIVATE_KEY is not set")
    relayer = Account.from_key(pk)

    if onchain_feed != feed_id:
        if onchain_feed != 0:
            die(f"on-chain feedId {onchain_feed} != ATLAS_BNB_FEED_ID {feed_id} (locked after the first submit)")
        if not args.set_feed_id:
            die("on-chain feedId is 0 (unset); rerun with --set-feed-id to set it from the owner key")
        # setFeedId is locked forever by the first submit (by anyone), so refuse ids that are clearly not BNB/USD.
        if not BNB_USD_SANE[0] <= price / 1e18 <= BNB_USD_SANE[1]:
            die(
                f"feed {feed_id} prices at {price / 1e18:.4f} USD, outside the plausible BNB/USD range "
                f"{BNB_USD_SANE}; refusing to lock it as the feedId"
            )
        owner_acct = Account.from_key(env.get("ADMIN_PRIVATE_KEY") or pk)
        (owner,) = abi_decode(["address"], rpc.call(feed_addr, sel("owner()")))
        if owner.lower() != owner_acct.address.lower():
            die(f"feed owner is {owner}; the configured owner key does not match")
        set_data = sel("setFeedId(uint32)") + abi_encode(["uint32"], [feed_id])
        rpc.call(feed_addr, set_data, owner_acct.address)
        if args.dry_run:
            print(f"dry-run: would call setFeedId({feed_id}); submit simulation skipped (needs the feedId set)")
            return
        send_tx(rpc, owner_acct, feed_addr, set_data, chain_id, "setFeedId")

    submit_data = sel("submit(bytes,bytes)") + abi_encode(["bytes", "bytes"], [payload, signature])
    try:
        rpc.call(feed_addr, submit_data, relayer.address)
    except RuntimeError as e:
        die(f"submit simulation reverted: {e}")
    if args.dry_run:
        print("dry-run: submit simulation OK; not sent")
        return
    tx_hash = send_tx(rpc, relayer, feed_addr, submit_data, chain_id, "submit")
    for _ in range(10):  # public RPCs are load-balanced: a node may lag the block that mined the submit
        _, answer, _, updated_at, _ = abi_decode(
            ["uint80", "int256", "uint256", "uint256", "uint80"], rpc.call(feed_addr, sel("latestRoundData()"))
        )
        if updated_at >= ts:
            break
        time.sleep(2)
    if updated_at < ts:
        print(f"warning: RPC node still shows the previous price (updatedAt {updated_at} < report ts {ts}); "
              f"check tx {tx_hash} on the explorer")
    print(f"on-chain now: {answer / 1e8:.4f} USD (8 dp), updatedAt {updated_at}  tx {tx_hash}")


if __name__ == "__main__":
    main()
