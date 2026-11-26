#!/usr/bin/env python
"""Simulate a watcher detecting a credential revocation, and optionally push it on-chain.

1. TEL (always): revokes the persona's leaf credential the same way
   make_test_chain.py's Issuer.revoke does. A `rev` TEL event is created, its seal
   is anchored in the issuer's KEL with an interaction event (signed through the
   demo keystore), the issuer KEL is re-exported to data/watcher/kel/<aid>.cesr
   and the event is appended to data/watcher/tel/<said>.json. After this, the
   verifier rejects the persona at the "revocation" check.

2. On-chain (with --push): as the registry admin, calls
       VLEIRegistry.revokeWallet(wallet, reason)   for --wallet <addr>
       VLEIRegistry.revokeEntity(leiHash, reason)  with --entity
   over JSON-RPC (eth_account signs the tx; httpx sends it).

Usage:
    python scripts/revoke_and_push.py bob
    python scripts/revoke_and_push.py bob --wallet 0xBob... --push
    python scripts/revoke_and_push.py bob --entity --push --rpc http://127.0.0.1:8545

Env (repo-root .env is loaded by app.config):
    VLEI_DATA_DIR          data dir to modify (default backend/data)
    RPC_URL / BSC_TESTNET_RPC, REGISTRY_ADDRESS (or contracts/deployments/<CHAIN_ID>.json),
    ADMIN_PRIVATE_KEY (falls back to DEPLOYER_PRIVATE_KEY)
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
import warnings
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
warnings.filterwarnings("ignore", category=SyntaxWarning)

from app.config import DATA_DIR, settings  # noqa: E402
from app.vlei.acdc import make_tel_event  # noqa: E402
from app.vlei.attest import lei_hash  # noqa: E402
from app.vlei.keystore import open_keystore  # noqa: E402

WATCHER = DATA_DIR / "watcher"
WALLETS = DATA_DIR / "wallets"


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def load_persona(pid: str) -> dict:
    p = WALLETS / f"{pid}.json"
    if "/" in pid or not p.exists():
        raise SystemExit(f"unknown persona '{pid}' (no {p})")
    return json.loads(p.read_text())


def revoke_tel(pid: str) -> dict:
    """Revoke the persona's leaf credential in its TEL. Idempotent."""
    w = load_persona(pid)
    said = w["leafSaid"]
    leaf = next(c["sad"] for c in w["credentials"] if c["sad"]["d"] == said)
    tel_path = WATCHER / "tel" / f"{said}.json"
    events = json.loads(tel_path.read_text())
    if events and events[-1]["t"] == "rev":
        return {"persona": pid, "said": said, "issuer": leaf["i"], "alreadyRevoked": True, "event": events[-1]}

    with open_keystore() as hby:
        hab = hby.habs.get(leaf["i"])
        if hab is None:
            raise SystemExit(f"issuer {leaf['i']} of {pid}'s credential is not in the demo keystore")
        prior = events[-1]
        evt = make_tel_event(ilk="rev", cred_said=said, sn=len(events), registry=leaf["ri"], dt=_now(),
                             prior=prior["d"])
        hab.interact(data=[{"i": said, "s": evt["s"], "d": evt["d"]}])
        kel = bytes(hab.replay())

    # Watcher export: KEL first (so the anchor exists before the TEL references it).
    (WATCHER / "kel" / f"{leaf['i']}.cesr").write_bytes(kel)
    events.append(evt)
    tel_path.write_text(json.dumps(events, indent=2))
    return {"persona": pid, "said": said, "issuer": leaf["i"], "alreadyRevoked": False, "event": evt}


# ---------------------------------------------------------------- on-chain push


def _rpc(url: str, method: str, params: list):
    import httpx

    r = httpx.post(url, json={"jsonrpc": "2.0", "id": 1, "method": method, "params": params}, timeout=30)
    r.raise_for_status()
    body = r.json()
    if "error" in body:
        raise RuntimeError(f"{method}: {body['error']}")
    return body["result"]


def send_admin_tx(*, rpc: str, registry: str, admin_key: str, fn_sig: str, types: list[str], args: list) -> dict:
    from eth_abi import encode
    from eth_account import Account
    from eth_utils import keccak, to_checksum_address

    acct = Account.from_key(admin_key)
    data = keccak(text=fn_sig)[:4] + encode(types, args)
    tx = {
        "from": acct.address,
        "to": to_checksum_address(registry),
        "data": "0x" + data.hex(),
        "value": 0,
        "chainId": int(_rpc(rpc, "eth_chainId", []), 16),
        "nonce": int(_rpc(rpc, "eth_getTransactionCount", [acct.address, "pending"]), 16),
        "gasPrice": int(_rpc(rpc, "eth_gasPrice", []), 16),
    }
    # eth_estimateGas surfaces reverts (e.g. caller lacks DEFAULT_ADMIN_ROLE) before sending.
    est = {k: (hex(v) if isinstance(v, int) else v) for k, v in tx.items() if k not in ("chainId", "nonce")}
    tx["gas"] = int(int(_rpc(rpc, "eth_estimateGas", [est]), 16) * 12 // 10)
    signed = acct.sign_transaction(tx)
    raw = getattr(signed, "raw_transaction", None) or signed.rawTransaction
    txh = _rpc(rpc, "eth_sendRawTransaction", ["0x" + bytes(raw).hex().removeprefix("0x")])
    for _ in range(120):
        rcpt = _rpc(rpc, "eth_getTransactionReceipt", [txh])
        if rcpt:
            if int(rcpt["status"], 16) != 1:
                raise RuntimeError(f"{fn_sig} reverted in tx {txh}")
            return {"tx": txh, "block": int(rcpt["blockNumber"], 16)}
        time.sleep(1)
    raise RuntimeError(f"timed out waiting for {txh}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("persona", help="persona id, e.g. bob")
    ap.add_argument("--wallet", help="wallet to revoke on-chain via revokeWallet()")
    ap.add_argument("--entity", action="store_true", help="also call revokeEntity(keccak256(LEI)) on-chain")
    ap.add_argument("--push", action="store_true", help="send the on-chain revocation(s)")
    ap.add_argument("--rpc", default=os.getenv("RPC_URL") or os.getenv("BSC_TESTNET_RPC", ""))
    ap.add_argument("--registry", default=settings.registry_address)
    ap.add_argument("--admin-key", default=os.getenv("ADMIN_PRIVATE_KEY") or os.getenv("DEPLOYER_PRIVATE_KEY", ""))
    ap.add_argument("--reason", default="")
    ap.add_argument("--skip-tel", action="store_true", help="only push on-chain")
    a = ap.parse_args()

    w = load_persona(a.persona)
    if not a.skip_tel:
        r = revoke_tel(a.persona)
        state = "already revoked" if r["alreadyRevoked"] else f"rev event {r['event']['d']} anchored in issuer KEL"
        print(f"TEL   {a.persona}: leaf {r['said']} ({state})")
        print(f"      issuer {r['issuer']}  data dir {DATA_DIR}")

    if (a.wallet or a.entity) and not a.push:
        print("on-chain: dry run (add --push to send)")
    if a.push:
        if not (a.wallet or a.entity):
            raise SystemExit("--push needs --wallet <addr> and/or --entity")
        missing = [n for n, v in (("--rpc", a.rpc), ("--registry", a.registry), ("--admin-key", a.admin_key)) if not v]
        if missing:
            raise SystemExit(f"--push needs {', '.join(missing)}")
        reason = a.reason or f"TEL revocation of {w['credentialType']} {w['leafSaid']}"
        if a.wallet:
            r = send_admin_tx(rpc=a.rpc, registry=a.registry, admin_key=a.admin_key,
                              fn_sig="revokeWallet(address,string)", types=["address", "string"],
                              args=[a.wallet, reason])
            print(f"chain revokeWallet({a.wallet}) tx {r['tx']} block {r['block']}")
        if a.entity:
            lh = lei_hash(w["lei"])
            r = send_admin_tx(rpc=a.rpc, registry=a.registry, admin_key=a.admin_key,
                              fn_sig="revokeEntity(bytes32,string)", types=["bytes32", "string"],
                              args=[bytes.fromhex(lh[2:]), reason])
            print(f"chain revokeEntity({lh}) tx {r['tx']} block {r['block']}")


if __name__ == "__main__":
    main()
