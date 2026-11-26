"""Cournot Intelligence Oracle: market-implied rate risk for the tokenized-Treasury offering.

Live API (same calls as the official skill's client, `cournot-ai/cournot-skills`):
  POST {COURNOT_API_BASE}/intelligence/v1/resolve      {"message", "limit"}        free: find matching markets
  POST {COURNOT_API_BASE}/intelligence/v1/probability  {"message", "market_ids"}   probability + basis (evidence)
Auth: header `COURNOT-API-KEY` when COURNOT_API_KEY is set; otherwise Cournot's free quota (3 calls per IP).

The question asks whether the 10-year US Treasury yield ends 2026 above 4.74%. Higher yields mean lower
Treasury prices, the main risk of a tokenized-Treasury offering. If probability >= COURNOT_RISK_THRESHOLD the
KYB Portal shows a rate-risk notice that each investor must acknowledge before contributing.

Every live call is written (client IP redacted, no key) to logs/cournot/live/. Live calls are spent only on
an explicit refresh; otherwise the latest logged live assessment is served with its timestamp, so the demo
does not burn the quota. There is no mock: if no live assessment exists and Cournot is unreachable, the
endpoint errors.
"""
from __future__ import annotations

import json
import time
from datetime import datetime, timezone
from pathlib import Path

import httpx

from ..config import LOG_DIR, Settings

LIVE_DIR = LOG_DIR / "cournot" / "live"

# Text added by vLEI-Gate (not returned by Cournot); the UI labels it as such.
APP_NOTE = (
    "vLEI-Gate interpretation: the offering holds US Treasuries, whose prices fall when yields rise. "
    "If Cournot's probability that the 10Y yield ends 2026 above 4.74% is at or above the threshold, "
    "investors must acknowledge a rate-risk notice before contributing."
)


class CournotError(Exception):
    def __init__(self, msg: str, status: int = 502):
        super().__init__(msg)
        self.status = status


def _headers(s: Settings) -> dict:
    h = {"content-type": "application/json"}
    if s.cournot_api_key:
        h["COURNOT-API-KEY"] = s.cournot_api_key
    return h


_SECRET_FIELDS = {"ip", "api_key", "key", "wallet", "address", "payer", "signature", "authorization"}


def _sanitize(value):
    """Redact client IP and any key / wallet / signature fields anywhere in the response before logging or returning."""
    if isinstance(value, dict):
        return {k: ("<redacted>" if k.lower() in _SECRET_FIELDS and v not in (None, "") else _sanitize(v)) for k, v in value.items()}
    if isinstance(value, list):
        return [_sanitize(v) for v in value]
    return value


async def resolve(s: Settings, message: str, limit: int = 5) -> list[dict]:
    """Free market search (no quota)."""
    async with httpx.AsyncClient(timeout=30) as c:
        r = await c.post(f"{s.cournot_api_base}/intelligence/v1/resolve", json={"message": message, "limit": limit},
                         headers={"content-type": "application/json"})
    try:
        body = r.json() if r.text.strip() else {}
    except ValueError:
        raise CournotError(f"resolve returned non-JSON (HTTP {r.status_code})")
    if r.status_code != 200 or not isinstance(body, dict) or body.get("code") != 0:
        raise CournotError(f"resolve failed: HTTP {r.status_code} code {body.get('code')} {body.get('msg', '')}")
    return body["data"].get("markets") or []


_last_live_call = 0.0


async def live_call(s: Settings) -> dict:
    """One paid/free-quota probability call. Logs the sanitized exchange and returns the parsed result."""
    global _last_live_call
    wait = s.cournot_min_refresh_seconds - (time.monotonic() - _last_live_call)
    if _last_live_call and wait > 0:
        raise CournotError(f"live Cournot calls are limited to one per {s.cournot_min_refresh_seconds} s (retry in {int(wait)} s)", 429)
    _last_live_call = time.monotonic()
    market_ids = [m for m in s.cournot_market_ids if m]
    if not market_ids:
        markets = await resolve(s, s.cournot_question)
        market_ids = [str(markets[0]["market_info"]["id"])] if markets else []
    if not market_ids:
        raise CournotError("no Cournot market matches the question")
    req = {"message": s.cournot_question, "market_ids": market_ids}
    t0 = time.monotonic()
    async with httpx.AsyncClient(timeout=120) as c:
        r = await c.post(f"{s.cournot_api_base}/intelligence/v1/probability", json=req, headers=_headers(s))
    ms = int((time.monotonic() - t0) * 1000)
    try:
        body = r.json()
    except ValueError:
        raise CournotError(f"Cournot returned non-JSON (HTTP {r.status_code})")
    if r.status_code == 402:
        raise CournotError("Cournot free quota used up (HTTP 402): set COURNOT_API_KEY from a Cournot pack", 402)
    if r.status_code == 429:
        raise CournotError("Cournot rate limit (HTTP 429)", 429)
    if not isinstance(body, dict):
        raise CournotError(f"Cournot returned an unexpected body (HTTP {r.status_code})")
    if r.status_code != 200 or body.get("code") != 0:
        raise CournotError(f"Cournot error: HTTP {r.status_code} code {body.get('code')} {body.get('msg', '')}")
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    LIVE_DIR.mkdir(parents=True, exist_ok=True)
    record = {
        "requestedAt": stamp,
        "endpoint": f"POST {s.cournot_api_base}/intelligence/v1/probability",
        "request": req,
        "httpStatus": r.status_code,
        "latencyMs": ms,
        "paymentRequiredHeader": bool(r.headers.get("payment-required")),
        "response": _sanitize(body),
        "sanitized": "client IP, keys, wallets and signatures redacted; API key never logged",
    }
    try:
        result = parse_record(record, f"{stamp}-probability.json", s, cached=False)
    except CournotError:
        # keep the raw exchange for debugging, but outside the *-probability.json set the UI reads
        (LIVE_DIR / f"{stamp}-invalid.json").write_text(json.dumps(record, indent=2))
        raise
    (LIVE_DIR / f"{stamp}-probability.json").write_text(json.dumps(record, indent=2))
    return result


def _iso(stamp: str) -> str:
    try:
        return datetime.strptime(stamp, "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc).isoformat(timespec="seconds")
    except ValueError:
        return stamp


def parse_record(record: dict, file: str, s: Settings, *, cached: bool) -> dict:
    data = (record.get("response") or {}).get("data")
    if not isinstance(data, dict):
        raise CournotError("Cournot response has no data object")
    raw_p = data.get("probability")
    if raw_p is None and isinstance(data.get("result"), dict):
        raw_p = data["result"].get("point_estimate")
    if isinstance(raw_p, dict):
        raw_p = raw_p.get("point_estimate", raw_p.get("value"))
    try:
        prob = float(raw_p)
    except (TypeError, ValueError):
        raise CournotError("Cournot response has no numeric probability")
    if not 0.0 <= prob <= 1.0:
        raise CournotError(f"Cournot probability {prob} is outside [0, 1]")
    markets = data.get("markets") or []
    m0 = (markets[0] if markets else {}).get("market_info", {})
    basis = data.get("basis") or []
    evidence = [
        {"title": b.get("summary", ""), "url": b.get("url", ""), "source": b.get("source", ""), "time": b.get("time", "")}
        for b in (basis if isinstance(basis, list) else [basis]) if isinstance(b, dict)
    ]
    return {
        "source": "cournot",
        "question": record["request"]["message"],
        "claim": m0.get("title", ""),
        "claimDetail": m0.get("description", ""),
        "marketId": str(m0.get("id", "")),
        "marketEnd": m0.get("end_time", ""),
        "matchingConfidence": (markets[0] if markets else {}).get("matching_confidence"),
        "probability": prob,
        "evidence": evidence,
        "requestId": "",  # Cournot's probability response carries no request id; the log file is the proof
        "logFile": f"logs/cournot/live/{file}",
        "billing": data.get("billing"),
        "charged": data.get("charged"),
        "askedAt": _iso(record.get("requestedAt", "")),
        "latencyMs": record.get("latencyMs", 0),
        "cached": cached,
        "highRisk": prob >= s.cournot_risk_threshold,
        "threshold": s.cournot_risk_threshold,
        "appNote": APP_NOTE,
        "topic": "rate_risk",
        "entity": "",
        "lei": "",
    }


def _live_files() -> list[Path]:
    return sorted(LIVE_DIR.glob("*-probability.json"), reverse=True) if LIVE_DIR.exists() else []


def latest(s: Settings) -> dict | None:
    for f in _live_files():
        try:
            rec = json.loads(f.read_text())
            if rec.get("httpStatus") == 200 and rec["response"].get("code") == 0:
                return parse_record(rec, f.name, s, cached=True)
        except Exception:  # noqa: BLE001 - a malformed log must never take the endpoint down
            continue
    return None


def history(s: Settings, limit: int = 20) -> list[dict]:
    out = []
    for f in _live_files()[:limit]:
        try:
            out.append(parse_record(json.loads(f.read_text()), f.name, s, cached=True))
        except Exception:  # noqa: BLE001
            continue
    return out


async def assessment(s: Settings, *, refresh: bool, name: str = "", lei: str = "") -> dict:
    """Latest logged live assessment; a new live call only on refresh (404 if none has been logged yet)."""
    cached = latest(s)
    if not refresh and cached is None:
        raise CournotError("no live Cournot assessment yet: request one with refresh=true", 404)
    if refresh and not s.cournot_allow_refresh:
        raise CournotError("live Cournot calls are disabled on this deployment (COURNOT_ALLOW_REFRESH=false)", 403)
    if refresh:
        try:
            res = await live_call(s)
        except (CournotError, httpx.HTTPError) as e:
            if cached is None:
                raise CournotError(str(e), getattr(e, "status", 502))
            res = {**cached, "refreshError": str(e)}
    else:
        res = cached
    return {**res, "entity": name, "lei": lei}
