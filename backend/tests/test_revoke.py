"""scripts/revoke_and_push.py (TEL part) against a COPY of backend/data.

The script runs in a subprocess with VLEI_DATA_DIR pointing at the copy, so the
real data (and app.config in this process) is never touched.
"""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import sys
import warnings
from pathlib import Path

warnings.filterwarnings("ignore", category=SyntaxWarning)

import pytest  # noqa: E402
from eth_account import Account  # noqa: E402
from eth_account.messages import encode_defunct  # noqa: E402

from app.config import BACKEND_DIR, DATA_DIR, Settings  # noqa: E402
from app.vlei import agent  # noqa: E402
from app.vlei.verifier import ChallengeStore, Verifier  # noqa: E402

SCRIPT = BACKEND_DIR / "scripts" / "revoke_and_push.py"
REGISTRY = "0x000000000000000000000000000000000000dEaD"


def _fingerprint(d: Path) -> str:
    h = hashlib.sha256()
    for p in sorted((d / "watcher").rglob("*")):
        if p.is_file():
            h.update(p.name.encode() + p.read_bytes())
    return h.hexdigest()


@pytest.fixture()
def data_copy(tmp_path):
    dst = tmp_path / "data"
    shutil.copytree(DATA_DIR, dst, ignore=shutil.ignore_patterns("*.lock"))
    return dst


def _verify(data_dir: Path, persona: str):
    s = Settings()
    s.watcher_dir = data_dir / "watcher"
    s.registry_address = REGISTRY
    s.verifier_private_key = "0x" + "22" * 32
    store = ChallengeStore(300)
    v = Verifier(s, store)
    w = json.loads((data_dir / "wallets" / f"{persona}.json").read_text())
    acct = Account.create()
    ch = store.issue(wallet=acct.address, holder=w["aid"], chain_id=97, registry=REGISTRY)
    # Holder keys are not touched by revocation, so the real demo keystore can sign.
    hsig = agent.sign_with_persona(persona, ch.message)["signature"]
    wsig = acct.sign_message(encode_defunct(text=ch.message)).signature.hex()
    return v.verify({"challengeId": ch.id, "leafSaid": w["leafSaid"], "credentials": w["credentials"],
                     "holderSignature": hsig, "walletSignature": "0x" + wsig.removeprefix("0x")})


def _run_script(data_dir: Path, *args: str) -> subprocess.CompletedProcess:
    env = {**os.environ, "VLEI_DATA_DIR": str(data_dir)}
    return subprocess.run([sys.executable, str(SCRIPT), *args], env=env, capture_output=True, text=True,
                          cwd=BACKEND_DIR, timeout=120)


def test_revoke_bob_in_tel_copy(data_copy):
    real_before = _fingerprint(DATA_DIR)
    assert _verify(data_copy, "bob").ok

    r = _run_script(data_copy, "bob")
    assert r.returncode == 0, r.stderr
    assert "anchored in issuer KEL" in r.stdout

    w = json.loads((data_copy / "wallets" / "bob.json").read_text())
    tel = json.loads((data_copy / "watcher" / "tel" / f"{w['leafSaid']}.json").read_text())
    assert [e["t"] for e in tel] == ["iss", "rev"]

    res = _verify(data_copy, "bob")
    assert not res.ok
    assert next(c.id for c in res.checks if c.ok is False) == "revocation"

    # Same issuer (le-andaman), different credential: still valid after the issuer KEL grew.
    assert _verify(data_copy, "erin").ok

    # Idempotent: a second run adds nothing.
    r = _run_script(data_copy, "bob")
    assert r.returncode == 0 and "already revoked" in r.stdout
    assert len(json.loads((data_copy / "watcher" / "tel" / f"{w['leafSaid']}.json").read_text())) == 2

    assert _fingerprint(DATA_DIR) == real_before, "real backend/data was modified"
