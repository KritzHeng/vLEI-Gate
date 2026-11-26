"""Demo keystore shared by the test-chain generator and the demo holder agent.

All test parties (root, QVI, entities, people) live in one keripy Habery for
convenience. In a real deployment each party runs its own KERIA agent / Signify
client and the verifier never has access to anyone's keys.
"""
from __future__ import annotations

from contextlib import contextmanager

from keri.app import habbing

from ..config import DATA_DIR

KEYSTORE_NAME = "vlei-demo"
KEYSTORE_DIR = DATA_DIR / "keystore"


@contextmanager
def open_keystore():
    KEYSTORE_DIR.mkdir(parents=True, exist_ok=True)
    with habbing.openHby(name=KEYSTORE_NAME, base="", temp=False, headDirPath=str(KEYSTORE_DIR)) as hby:
        yield hby
