"""Pre-demo checklist: run right before recording or presenting.

  backend/.venv/bin/python scripts/preflight.py           check, and push a fresh Atlas price if it is getting old
  backend/.venv/bin/python scripts/preflight.py --no-push check only (sends no transaction)
  backend/.venv/bin/python scripts/preflight.py --live    check the hosted demo (Fly.io) instead of localhost

Checks: backend + frontend up, Atlas price age (pushes via push_atlas_price.py when older than --push-after),
keeper running, Atlas vs CMC agreement, vLEI registration time left for the demo wallets, remaining entity cap on
the Atlas-priced BNB launch, tBNB balances, Cournot quota and the refresh-button flag.
Read-only except the optional Atlas push (DEPLOYER_PRIVATE_KEY, the same relayer key the keeper uses).
Never prints keys. Exit code 1 if any check FAILs (WARNs don't fail).
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

import httpx
from dotenv import dotenv_values
from eth_account import Account
from eth_utils import keccak

ROOT = Path(__file__).resolve().parents[1]
ENV = {k: v for k, v in dotenv_values(ROOT / ".env").items() if v}
FRONT_ENV = {k: v for k, v in dotenv_values(ROOT / "frontend/.env.local").items() if v}
RPC = ENV.get("RPC_URL") or "https://bsc-testnet-rpc.publicnode.com"
BACKEND = FRONT_ENV.get("NEXT_PUBLIC_BACKEND_URL", "http://localhost:8000").rstrip("/")
FRONTEND = "http://localhost:3000"
# Hosted demo (--live); override with LIVE_BACKEND_URL / LIVE_FRONTEND_URL in .env
LIVE_BACKEND = ENV.get("LIVE_BACKEND_URL", "https://vlei-gate-api.fly.dev").rstrip("/")
LIVE_FRONTEND = ENV.get("LIVE_FRONTEND_URL", "https://vlei-gate-kyb.fly.dev").rstrip("/")
ATLAS_FEED = json.loads((ROOT / "contracts/deployments/97-atlas.json").read_text())["atlasSignedFeed"]
REGISTRY = json.loads((ROOT / "contracts/deployments/97.json").read_text())["registry"]
BNB_LAUNCH = "0x206dB9B3b73Ca3f57a0cB1C8C3fc83cFDfcD609b"  # Atlas-priced BNB launch used in the demo (scene 5)
DEMO_WALLETS = ["DEMO_ALICE_PRIVATE_KEY", "DEMO_BOB_PRIVATE_KEY", "DEMO_ERIN_PRIVATE_KEY"]
ADMIN_KEY = "DEPLOYER_PRIVATE_KEY"
COURNOT_FREE_CALLS = 3

fails = 0
G, Y, R, X = "\033[32m", "\033[33m", "\033[31m", "\033[0m"


def ok(msg: str) -> None:
    print(f"  {G}OK  {X} {msg}")


def warn(msg: str) -> None:
    print(f"  {Y}WARN{X} {msg}")


def fail(msg: str) -> None:
    global fails
    fails += 1
    print(f"  {R}FAIL{X} {msg}")


def call(to: str, sig: str, *args: str) -> bytes:
    data = "0x" + keccak(text=sig)[:4].hex() + "".join(a.lower().removeprefix("0x").rjust(64, "0") for a in args)
    r = httpx.post(RPC, json={"jsonrpc": "2.0", "id": 1, "method": "eth_call", "params": [{"to": to, "data": data}, "latest"]},
                   timeout=15)
    if r.status_code != 200:
        raise RuntimeError(f"RPC HTTP {r.status_code}")
    body = r.json()
    if "error" in body:
        raise RuntimeError(body["error"].get("message", "eth_call failed"))
    return bytes.fromhex(body["result"][2:])


def word(raw: bytes, i: int) -> int:
    return int.from_bytes(raw[32 * i:32 * i + 32], "big")


def balance(addr: str) -> float:
    r = httpx.post(RPC, json={"jsonrpc": "2.0", "id": 1, "method": "eth_getBalance", "params": [addr, "latest"]}, timeout=15)
    return int(r.json()["result"], 16) / 1e18


def chain_now() -> int:
    r = httpx.post(RPC, json={"jsonrpc": "2.0", "id": 1, "method": "eth_getBlockByNumber", "params": ["latest", False]},
                   timeout=15)
    return int(r.json()["result"]["timestamp"], 16)


def hm(sec: int) -> str:
    return f"{sec // 3600}h{(sec % 3600) // 60:02d}m"


def addr_of(var: str) -> str | None:
    key = ENV.get(var)
    return Account.from_key(key).address if key else None


def atlas_age() -> tuple[float, int]:
    raw = call(ATLAS_FEED, "latestRoundData()")
    return word(raw, 1) / 1e8, chain_now() - word(raw, 3)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--no-push", action="store_true", help="never send the Atlas price transaction")
    ap.add_argument("--push-after", type=int, default=1800, help="push a fresh Atlas price when older than this (s)")
    ap.add_argument("--min-left", type=int, default=7200, help="warn when a wallet's vLEI expires within this (s)")
    ap.add_argument("--live", action="store_true", help="check the hosted demo (Fly.io) instead of localhost")
    a = ap.parse_args()

    global BACKEND, FRONTEND
    if a.live:
        BACKEND, FRONTEND = LIVE_BACKEND, LIVE_FRONTEND
    fix_backend = ("fly status -a vlei-gate-api (if stopped: fly apps restart vlei-gate-api)" if a.live
                   else "cd backend && .venv/bin/uvicorn app.main:app --port 8000")
    fix_frontend = ("fly status -a vlei-gate-kyb (if stopped: fly apps restart vlei-gate-kyb)" if a.live
                    else "cd frontend && npm run dev")

    print(f"1. Services ({'hosted demo' if a.live else 'localhost'})")
    health: dict = {}
    try:
        health = httpx.get(f"{BACKEND}/api/health", timeout=30).json()
        ok(f"backend {BACKEND} (chain {health.get('chainId')}, demo agent {health.get('demoAgent')}, "
           f"Cournot {health.get('cournotMode')})")
        if not health.get("demoAgent"):
            fail("demo agent disabled on the backend: the KYB scene cannot sign the holder challenge (ENABLE_DEMO_AGENT=true)")
    except Exception as e:  # noqa: BLE001
        fail(f"backend {BACKEND} not reachable ({type(e).__name__}): {fix_backend}")
    pages = ["", "/verify", f"/offerings/{BNB_LAUNCH}", "/portfolio"] if a.live else [""]
    for page in pages:
        try:
            code = httpx.get(f"{FRONTEND}{page}", timeout=60).status_code
            (ok if code == 200 else fail)(f"frontend {FRONTEND}{page or '/'} -> HTTP {code}"
                                          + ("" if code == 200 else f": {fix_frontend}"))
        except Exception as e:  # noqa: BLE001
            fail(f"frontend {FRONTEND}{page or '/'} not reachable ({type(e).__name__}): {fix_frontend}")

    print("2. Atlas BNB/USD price")
    try:
        price, age = atlas_age()
        if age > a.push_after and not a.no_push:
            print(f"       price is {hm(age)} old: pushing a fresh signed Atlas report ...")
            p = subprocess.run([sys.executable, str(ROOT / "scripts/push_atlas_price.py")], capture_output=True, text=True,
                               timeout=240)
            lines = [ln for ln in (p.stdout + p.stderr).splitlines() if "key" not in ln.lower() and "private" not in ln.lower()]
            print("\n".join("       " + ln for ln in lines[-3:]))
            price, age = atlas_age()
        if age > 3600:
            fail(f"${price:,.2f}, {hm(age)} old (> 1h): BNB contributions revert StalePrice. Run scripts/push_atlas_price.py")
        elif age > a.push_after:
            warn(f"${price:,.2f}, {hm(age)} old: stale in {hm(3600 - age)}")
        else:
            ok(f"${price:,.2f}, {age // 60} min old (stale after 60 min)")
    except Exception as e:  # noqa: BLE001
        fail(f"cannot read AtlasSignedFeed ({e})")
    keeper = subprocess.run(["pgrep", "-f", "atlas_keeper"], capture_output=True, text=True).stdout.strip()
    if keeper:
        ok("Atlas keeper running (it stalls while the Mac sleeps: run it under `caffeinate -i`)")
    else:
        warn("Atlas keeper not running: caffeinate -i scripts/atlas_keeper.sh  (else the price is stale 1h after this push)")
    try:
        pc = httpx.get(f"{BACKEND}/api/market/price-check", timeout=20).json()
        if pc.get("ok"):
            ok(f"Atlas vs CoinMarketCap agree ({pc.get('deviationBps')} bps, max {pc.get('maxDeviationBps')})")
        else:
            fail(f"price check {pc.get('status')}: {pc.get('reason')}  (BNB contributions are paused in the UI)")
    except Exception as e:  # noqa: BLE001
        fail(f"price check unavailable ({type(e).__name__})")

    print("3. vLEI registrations (24 h each; re-verify at /verify; only alice is required by the demo script)")
    now = None
    try:
        now = chain_now()
    except Exception as e:  # noqa: BLE001
        fail(f"RPC unreachable ({type(e).__name__})")
    for var in DEMO_WALLETS:
        who = var.removeprefix("DEMO_").removesuffix("_PRIVATE_KEY").lower()
        addr = addr_of(var)
        if not addr:
            warn(f"{who}: {var} not set")
            continue
        if now is None:
            continue
        try:
            active = word(call(REGISTRY, "isActive(address)", addr), 0) == 1
            exp = word(call(REGISTRY, "getRegistration(address)", addr), 2)
            revoked = word(call(REGISTRY, "walletRevoked(address)", addr), 0) == 1
            left = exp - now
            if revoked:
                (fail if who == "alice" else warn)(
                    f"{who} {addr[:6]}…{addr[-4:]}: wallet revoked. Re-verify at /verify (register clears it)")
            elif not active:
                (fail if who == "alice" else warn)(f"{who} {addr[:6]}…{addr[-4:]}: not active"
                                                   + (" (expired)" if exp else " (never registered)") + ". Re-verify at /verify")
            elif left < a.min_left:
                (fail if who == "alice" else warn)(f"{who}: active but expires in {hm(left)}. Re-verify before recording")
            else:
                ok(f"{who}: active, {hm(left)} left")
        except Exception as e:  # noqa: BLE001
            fail(f"{who}: registry read failed ({e})")

    print(f"4. Atlas-priced BNB launch {BNB_LAUNCH[:6]}…{BNB_LAUNCH[-4:]}")
    alice = addr_of("DEMO_ALICE_PRIVATE_KEY")
    try:
        status = word(call(BNB_LAUNCH, "status()"), 0)
        deadline = word(call(BNB_LAUNCH, "saleDeadline()"), 0)
        if status != 0:
            fail(f"status {status} (not Raising): scene 5 needs a launch that is still raising")
        elif now and deadline - now < 86400:
            warn(f"sale closes in {hm(deadline - now)}")
        else:
            ok(f"raising, closes in {(deadline - now) // 86400 if now else '?'} days")
        if alice:
            cap = word(call(BNB_LAUNCH, "remainingCapUsd(address)", alice), 0) / 1e18
            px = word(call(BNB_LAUNCH, "bnbUsdPrice()"), 0) / 1e18
            bnb = f" (~{cap / px:.4f} BNB)" if px else ""
            if cap < 1:
                fail(f"alice's entity cap left ${cap:.2f}{bnb}: contributions revert CapExceeded. Create a new launch")
            elif cap < 3:
                warn(f"alice's entity cap left ${cap:.2f}{bnb}: one small contribution at most")
            else:
                ok(f"alice's entity cap left ${cap:.2f}{bnb}")
    except Exception as e:  # noqa: BLE001
        fail(f"launch read failed ({e})")

    print("5. tBNB for gas")
    for var, need in [(v, 0.01) for v in DEMO_WALLETS] + [(ADMIN_KEY, 0.02)]:
        addr = addr_of(var)
        if not addr:
            continue
        who = "admin/relayer" if var == ADMIN_KEY else var.removeprefix("DEMO_").removesuffix("_PRIVATE_KEY").lower()
        try:
            b = balance(addr)
            (ok if b >= need else warn)(f"{who} {addr[:6]}…{addr[-4:]}: {b:.4f} tBNB" + ("" if b >= need else f" (< {need})"))
        except Exception as e:  # noqa: BLE001
            warn(f"{who}: balance read failed ({type(e).__name__})")

    print("6. Cournot")
    live = sorted((ROOT / "logs/cournot/live").glob("*-probability.json"))
    if a.live:  # the hosted backend serves the logs baked into its image, not this machine's
        try:
            r = httpx.get(f"{BACKEND}/api/oracle/cournot-latest", timeout=15)
            if r.status_code == 200:
                ok(f"hosted backend serves a live result p = {r.json().get('probability')}")
            else:
                fail(f"hosted backend has no live Cournot result (HTTP {r.status_code}): the contribute gate stays closed")
        except Exception as e:  # noqa: BLE001
            fail(f"Cournot latest unavailable ({type(e).__name__})")
        if health.get("cournotRefresh") is False:
            ok("live Cournot calls disabled on the server (refresh -> 403); no quota can be spent from the stage")
        else:
            warn("live Cournot calls enabled on the hosted backend: set COURNOT_ALLOW_REFRESH=false")
    elif not live:
        fail("no logged live Cournot result: the risk card and the contribute gate have nothing to show")
    else:
        try:
            latest = httpx.get(f"{BACKEND}/api/oracle/cournot-latest", timeout=10).json()
            ok(f"latest logged live result p = {latest.get('probability')} ({live[-1].name[:16]})")
        except Exception:  # noqa: BLE001
            ok(f"{len(live)} logged live result(s), latest {live[-1].name[:16]}")
    if not a.live:
        if ENV.get("COURNOT_API_KEY"):
            ok("COURNOT_API_KEY set (refresh uses the paid pack)")
        else:
            left = max(0, COURNOT_FREE_CALLS - len(live))
            warn(f"no COURNOT_API_KEY: about {left} free call(s) left from this IP. Don't press refresh on stage")
        if FRONT_ENV.get("NEXT_PUBLIC_COURNOT_REFRESH") == "false":
            ok("refresh button hidden (NEXT_PUBLIC_COURNOT_REFRESH=false)")
        else:
            warn("refresh button visible: set NEXT_PUBLIC_COURNOT_REFRESH=false in frontend/.env.local to hide it")

    print()
    print(f"{R}{fails} check(s) failed{X}" if fails else f"{G}Ready to record.{X}")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
