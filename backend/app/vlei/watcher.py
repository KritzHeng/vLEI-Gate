"""Watcher client: fetches KELs and TELs and validates key state with keripy.

In this build the watcher is a local directory written by
`scripts/make_test_chain.py` (and by `scripts/revoke_and_push.py`):

    data/watcher/kel/<AID>.cesr     CESR KEL stream (events + signatures)
    data/watcher/tel/<SAID>.json    TEL events for a credential

KELs are *not* trusted as-is: every stream is replayed through a fresh keripy
`Kevery`, which verifies signatures, pre-rotation commitments and sequence.
"""
from __future__ import annotations

import json
import uuid
from dataclasses import dataclass, field
from pathlib import Path

from keri.core import eventing, parsing, serdering
from keri.db import basing

from .acdc import tel_said_ok


class WatcherError(Exception):
    pass


@dataclass
class KeyState:
    aid: str
    sn: int
    verfers: list  # keri Verfer objects for the *current* signing keys
    threshold: str
    anchors: list[dict] = field(default_factory=list)  # seals from ixn/rot events

    def has_anchor(self, *, i: str, s: str, d: str) -> bool:
        return any(a.get("i") == i and a.get("s") == s and a.get("d") == d for a in self.anchors)

    @property
    def current_keys(self) -> list[str]:
        return [v.qb64 for v in self.verfers]


@dataclass
class TelState:
    cred_said: str
    status: str  # "issued" | "revoked" | "unknown"
    events: list[dict]


class Watcher:
    """One verification session. Use as a context manager so the temp DB is closed."""

    def __init__(self, root: Path):
        self.root = Path(root)
        self._db = basing.Baser(name=f"verifier-{uuid.uuid4().hex[:8]}", temp=True, reopen=True)
        self._kvy = eventing.Kevery(db=self._db, lax=True, local=False)
        self._cache: dict[str, KeyState] = {}

    def __enter__(self) -> "Watcher":
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    def close(self) -> None:
        try:
            self._db.close(clear=True)
        except Exception:
            pass

    # ---------------- KEL ----------------

    def key_state(self, aid: str) -> KeyState:
        if aid in self._cache:
            return self._cache[aid]
        path = self.root / "kel" / f"{aid}.cesr"
        if not path.exists():
            raise WatcherError(f"no KEL available for {aid}")
        parsing.Parser(kvy=self._kvy).parse(ims=bytearray(path.read_bytes()))
        kever = self._kvy.kevers.get(aid)
        if kever is None:
            raise WatcherError(f"KEL for {aid} failed validation")

        anchors: list[dict] = []
        for msg in self._db.clonePreIter(pre=aid, fn=0):
            serder = serdering.SerderKERI(raw=bytes(msg))
            for seal in serder.ked.get("a", []) or []:
                if isinstance(seal, dict):
                    anchors.append(seal)

        ks = KeyState(
            aid=aid,
            sn=kever.sn,
            verfers=list(kever.verfers),
            threshold=str(kever.tholder.sith),
            anchors=anchors,
        )
        self._cache[aid] = ks
        return ks

    # ---------------- TEL ----------------

    def tel_state(self, cred_said: str, issuer: str) -> TelState:
        path = self.root / "tel" / f"{cred_said}.json"
        if not path.exists():
            return TelState(cred_said, "unknown", [])
        events = json.loads(path.read_text())
        ks = self.key_state(issuer)
        status = "unknown"
        prior = None
        for n, evt in enumerate(events):
            if not tel_said_ok(evt):
                raise WatcherError(f"TEL event SAID mismatch for {cred_said}")
            if evt.get("i") != cred_said or int(evt.get("s", "-1"), 16) != n:
                raise WatcherError(f"TEL out of order for {cred_said}")
            if n and evt.get("p") != prior:
                raise WatcherError(f"TEL chain broken for {cred_said}")
            # Each TEL event must be anchored in the issuer's validated KEL.
            if not ks.has_anchor(i=cred_said, s=evt["s"], d=evt["d"]):
                raise WatcherError(f"TEL event {evt['t']} for {cred_said} not anchored in issuer KEL")
            status = {"iss": "issued", "rev": "revoked"}.get(evt["t"], status)
            prior = evt["d"]
        return TelState(cred_said, status, events)
