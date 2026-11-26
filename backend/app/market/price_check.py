"""Price sanity check: Atlas BNB/USD (on-chain, signed) vs CoinMarketCap.

Two independent sources must agree before BNB-quoted value is accepted. Used by the KYB Portal to block
contributions on Atlas-priced BNB launches when the sources disagree, and mirrored by the relayer
(`scripts/push_atlas_price.py`), which refuses to put a disagreeing Atlas price on-chain.

status:
  ok            both prices present, fresh, deviation <= max
  deviation     deviation > max                              -> block
  stale         on-chain Atlas price older than max age      -> block (the contracts revert StalePrice anyway)
  unavailable   a source could not be read                   -> block (fail closed)
"""
from __future__ import annotations

import time

import httpx

from ..config import Settings
from . import cmc

LATEST_ROUND_DATA = "0xfeaf968c"  # latestRoundData()
DECIMALS = 8


async def _atlas_onchain(s: Settings) -> dict:
    if not (s.rpc_url and s.atlas_signed_feed_address):
        raise RuntimeError("RPC_URL or Atlas feed address not configured")
    async with httpx.AsyncClient(timeout=15) as c:
        r = await c.post(s.rpc_url, json={"jsonrpc": "2.0", "id": 1, "method": "eth_call",
                                          "params": [{"to": s.atlas_signed_feed_address, "data": LATEST_ROUND_DATA}, "latest"]})
    body = r.json()
    if "error" in body:
        raise RuntimeError(f"eth_call failed: {body['error'].get('message', '')}")
    raw = bytes.fromhex(body["result"][2:])
    if len(raw) < 160:
        raise RuntimeError("short latestRoundData response")
    answer = int.from_bytes(raw[32:64], "big", signed=True)
    updated_at = int.from_bytes(raw[96:128], "big")
    if answer <= 0 or updated_at == 0:
        raise RuntimeError("Atlas feed has no price")
    return {"source": "atlas", "feed": s.atlas_signed_feed_address, "price": answer / 10**DECIMALS, "updatedAt": updated_at}


async def check(s: Settings) -> dict:
    now = int(time.time())
    out: dict = {"maxDeviationBps": s.price_deviation_max_bps, "maxAgeSeconds": s.price_max_age, "checkedAt": now,
                 "atlas": None, "cmc": None, "deviationBps": None}
    errors = []
    try:
        a = await _atlas_onchain(s)
        a["ageSeconds"] = max(0, now - a["updatedAt"])
        out["atlas"] = a
    except Exception as e:  # noqa: BLE001
        errors.append(f"atlas: {e}")
    try:
        q = await cmc.quote(s, "BNB", "USD")
        out["cmc"] = {"source": "coinmarketcap", "price": q["price"], "lastUpdated": q.get("lastUpdated")}
    except Exception as e:  # noqa: BLE001
        errors.append(f"cmc: {e}")

    if errors:
        out.update(status="unavailable", ok=False, reason="; ".join(errors))
        return out
    a, c = out["atlas"], out["cmc"]
    if not isinstance(c["price"], (int, float)) or c["price"] <= 0:
        out.update(status="unavailable", ok=False, reason="cmc: no valid BNB price")
        return out
    dev = abs(a["price"] - c["price"]) / c["price"] * 10_000
    out["deviationBps"] = round(dev, 1)
    if a["ageSeconds"] > s.price_max_age:
        out.update(status="stale", ok=False, reason=f"Atlas price is {a['ageSeconds']} s old (max {s.price_max_age} s)")
    elif dev > s.price_deviation_max_bps:
        out.update(status="deviation", ok=False,
                   reason=f"Atlas and CoinMarketCap differ by {dev:.1f} bps (max {s.price_deviation_max_bps})")
    else:
        out.update(status="ok", ok=True, reason="Atlas and CoinMarketCap agree")
    return out
