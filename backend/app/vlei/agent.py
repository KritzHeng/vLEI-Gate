"""Demo holder agent: a stand-in for each persona's Signify client / KERIA agent.

It only exposes "sign this challenge with persona X's current AID keys" and the
persona's credential bundle. The verifier never calls this module; it only sees
the resulting signature. Disable with ENABLE_DEMO_AGENT=false.
"""
from __future__ import annotations

import json

from ..config import DATA_DIR
from .keystore import open_keystore

WALLETS = DATA_DIR / "wallets"


def list_personas() -> list[dict]:
    out = []
    for p in sorted(WALLETS.glob("*.json")):
        w = json.loads(p.read_text())
        out.append({k: w[k] for k in ("id", "aid", "personLegalName", "entity", "lei", "credentialType", "role",
                                      "description", "scenario", "leafSaid")})
    order = ["alice", "bob", "erin", "carol", "dave", "mallory"]
    return sorted(out, key=lambda x: order.index(x["id"]) if x["id"] in order else 99)


def load_wallet(pid: str) -> dict:
    p = WALLETS / f"{pid}.json"
    if not p.exists() or "/" in pid:
        raise KeyError(pid)
    return json.loads(p.read_text())


def sign_with_persona(pid: str, message: str) -> dict:
    w = load_wallet(pid)
    with open_keystore() as hby:
        hab = hby.habByName(w["habName"])
        if hab is None:
            raise KeyError(pid)
        cigar = hab.sign(message.encode(), indexed=False)[0]
        return {"aid": hab.pre, "signature": cigar.qb64, "keySn": hab.kever.sn}
