"""Minimal ACDC handling: SAID computation and verification.

Credentials follow the ACDC field layout (v, d, i, ri, s, a, e, r). Nested
`a` and `e` blocks carry their own SAIDs, computed before the top-level SAID.
"""
from __future__ import annotations

import copy
import json

from keri.core import coring

ACDC_VERSION = "ACDC10JSON000000_"


def _saidify(block: dict) -> dict:
    blk = dict(block)
    blk["d"] = ""
    _, sad = coring.Saider.saidify(sad=blk, label="d")
    return sad


def make_credential(
    *, issuer: str, schema: str, attrs: dict, edges: dict | None = None, rules: dict | None = None, registry: str = ""
) -> dict:
    a = _saidify({"d": "", **attrs})
    sad = {"v": ACDC_VERSION, "d": "", "i": issuer, "ri": registry or f"{issuer}.reg", "s": schema, "a": a}
    if edges:
        sad["e"] = _saidify({"d": "", **edges})
    if rules:
        sad["r"] = _saidify({"d": "", **rules})
    return _saidify(sad)


def said_ok(sad: dict) -> bool:
    """Recompute every SAID in the credential and compare."""
    try:
        for key in ("a", "e", "r"):
            if key in sad and isinstance(sad[key], dict):
                if _saidify(sad[key])["d"] != sad[key]["d"]:
                    return False
        return _saidify(sad)["d"] == sad["d"]
    except Exception:
        return False


def serialize(sad: dict) -> bytes:
    """Canonical bytes that an issuer signs (field order preserved, compact)."""
    return json.dumps(sad, separators=(",", ":"), ensure_ascii=False).encode()


def make_tel_event(*, ilk: str, cred_said: str, sn: int, registry: str, dt: str, prior: str | None = None) -> dict:
    evt = {"v": "KERI10JSON000000_", "t": ilk, "d": "", "i": cred_said, "s": f"{sn:x}", "ri": registry, "dt": dt}
    if prior:
        evt["p"] = prior
    return _saidify(evt)


def tel_said_ok(evt: dict) -> bool:
    try:
        return _saidify(copy.deepcopy(evt))["d"] == evt["d"]
    except Exception:
        return False
