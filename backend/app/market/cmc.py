"""CoinMarketCap Pro API proxy (key stays server-side)."""
from __future__ import annotations

import time

import httpx

from ..config import Settings

_cache: dict[str, tuple[float, dict]] = {}
CACHE_SECONDS = 60


class CMCUnavailable(Exception):
    pass


async def quote(s: Settings, symbol: str = "BNB", convert: str = "USD") -> dict:
    if not s.cmc_api_key:
        raise CMCUnavailable("CMC_API_KEY not configured")
    key = f"{symbol}:{convert}"
    hit = _cache.get(key)
    if hit and time.time() - hit[0] < CACHE_SECONDS:
        return {**hit[1], "cached": True}

    try:
        async with httpx.AsyncClient(timeout=15) as client:
            r = await client.get(
                f"{s.cmc_base_url}/v1/cryptocurrency/quotes/latest",
                params={"symbol": symbol, "convert": convert},
                headers={"X-CMC_PRO_API_KEY": s.cmc_api_key, "Accept": "application/json"},
            )
    except httpx.HTTPError as e:
        raise CMCUnavailable(f"CMC unreachable ({type(e).__name__})") from None
    if r.status_code != 200:
        raise CMCUnavailable(f"CMC returned HTTP {r.status_code}")
    try:
        entry = r.json()["data"][symbol]
        entry = entry[0] if isinstance(entry, list) else entry
        q = entry["quote"][convert]
    except (ValueError, KeyError, IndexError, TypeError):
        raise CMCUnavailable(f"CMC has no {symbol}/{convert} quote") from None
    out = {
        "source": "coinmarketcap",
        "symbol": symbol,
        "convert": convert,
        "price": q["price"],
        "percentChange24h": q.get("percent_change_24h"),
        "lastUpdated": q.get("last_updated"),
        "endpoint": "/v1/cryptocurrency/quotes/latest",
        "cached": False,
    }
    _cache[key] = (time.time(), out)
    return out
