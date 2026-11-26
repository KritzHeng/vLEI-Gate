#!/usr/bin/env python
"""Generate a test vLEI ecosystem with keripy.

    test root -> QVI -> LE -> OOR / ECR   (+ negative cases)

Writes:
    data/keystore/          keripy Habery with every test party (demo only)
    data/watcher/kel/*.cesr KEL streams served by the local watcher
    data/watcher/tel/*.json TEL events per credential (anchored in issuer KELs)
    data/wallets/*.json     credential bundles each persona can present
    data/root.json          the pinned root AID

Usage:  python scripts/make_test_chain.py [--force]
"""
from __future__ import annotations

import argparse
import json
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import warnings  # noqa: E402

warnings.filterwarnings("ignore", category=SyntaxWarning)

from app.config import DATA_DIR  # noqa: E402
from app.vlei import schemas as S  # noqa: E402
from app.vlei.acdc import make_credential, make_tel_event, serialize  # noqa: E402
from app.vlei.keystore import open_keystore  # noqa: E402

WATCHER = DATA_DIR / "watcher"
WALLETS = DATA_DIR / "wallets"

RULES = {
    "usageDisclaimer": {"l": "Usage of a valid, unexpired, and non-revoked vLEI Credential does not assert that the "
                             "Legal Entity is trustworthy, honest, reputable in its business dealings, safe to do "
                             "business with, or compliant with any laws."},
    "issuanceDisclaimer": {"l": "TEST CREDENTIAL generated for the vLEI-Gate hackathon demo. Not a GLEIF vLEI."},
}


def now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


class Issuer:
    def __init__(self, hby):
        self.hby = hby
        self.habs: dict[str, object] = {}
        self.creds: dict[str, dict] = {}  # said -> {"sad", "signature"}
        self.tel: dict[str, list[dict]] = {}

    def hab(self, name: str):
        if name not in self.habs:
            self.habs[name] = self.hby.makeHab(name=name, icount=1, isith="1", ncount=1, nsith="1", transferable=True)
        return self.habs[name]

    def issue(self, issuer: str, schema: str, attrs: dict, edges: dict | None = None) -> dict:
        hab = self.hab(issuer)
        sad = make_credential(
            issuer=hab.pre, schema=schema, attrs={"dt": now(), **attrs}, edges=edges, rules=RULES,
            registry=f"{hab.pre}.reg",
        )
        evt = make_tel_event(ilk="iss", cred_said=sad["d"], sn=0, registry=sad["ri"], dt=now())
        hab.interact(data=[{"i": sad["d"], "s": evt["s"], "d": evt["d"]}])
        self.tel[sad["d"]] = [evt]
        self.creds[sad["d"]] = {"sad": sad, "signature": None, "issuerName": issuer}
        return sad

    def revoke(self, said: str) -> None:
        c = self.creds[said]
        hab = self.hab(c["issuerName"])
        prior = self.tel[said][-1]
        evt = make_tel_event(ilk="rev", cred_said=said, sn=len(self.tel[said]), registry=c["sad"]["ri"], dt=now(),
                             prior=prior["d"])
        hab.interact(data=[{"i": said, "s": evt["s"], "d": evt["d"]}])
        self.tel[said].append(evt)

    def sign(self, said: str) -> None:
        c = self.creds[said]
        hab = self.hab(c["issuerName"])
        cigar = hab.sign(serialize(c["sad"]), indexed=False)[0]
        c["signature"] = {"signer": hab.pre, "keySn": hab.kever.sn, "cigar": cigar.qb64}


def edge(sad: dict, schema: str) -> dict:
    return {"n": sad["d"], "s": schema}


def build(force: bool) -> None:
    if DATA_DIR.exists() and any(DATA_DIR.iterdir()):
        if not force:
            sys.exit(f"{DATA_DIR} is not empty; re-run with --force to regenerate")
        for sub in ("keystore", "watcher", "wallets", "root.json"):
            p = DATA_DIR / sub
            shutil.rmtree(p, ignore_errors=True) if p.is_dir() else p.unlink(missing_ok=True)
    for d in (WATCHER / "kel", WATCHER / "tel", WALLETS):
        d.mkdir(parents=True, exist_ok=True)

    LEI_QVI = S.lei_checksum("5493000TESTQVI0001")
    LEI_SIAM = S.lei_checksum("5493000SIAMTTC0001")
    LEI_ANDAMAN = S.lei_checksum("5493000ANDCAP00001")
    LEI_PHANTOM = S.lei_checksum("5493000PHANTOM0001")

    with open_keystore() as hby:
        x = Issuer(hby)

        # ---------------- legitimate ecosystem ----------------
        root = x.hab("test-gleif-root")
        for n in ("test-qvi", "le-siam", "le-andaman", "alice", "bob", "carol", "dave", "erin"):
            x.hab(n)

        qvi = x.issue("test-gleif-root", S.QVI, {"i": x.hab("test-qvi").pre, "LEI": LEI_QVI})

        le_siam = x.issue("test-qvi", S.LE, {"i": x.hab("le-siam").pre, "LEI": LEI_SIAM,
                                             "legalName": "Siam Tokenized Treasury Co., Ltd."},
                          {"qvi": edge(qvi, S.QVI)})
        le_and = x.issue("test-qvi", S.LE, {"i": x.hab("le-andaman").pre, "LEI": LEI_ANDAMAN,
                                            "legalName": "Andaman Capital Partners Ltd."},
                         {"qvi": edge(qvi, S.QVI)})

        def oor(person: str, le_name: str, le_sad: dict, name: str, role: str) -> dict:
            attrs = {"AID": x.hab(person).pre, "LEI": le_sad["a"]["LEI"], "personLegalName": name, "officialRole": role}
            auth = x.issue(le_name, S.OOR_AUTH, {"i": x.hab("test-qvi").pre, **attrs}, {"le": edge(le_sad, S.LE)})
            return x.issue("test-qvi", S.OOR,
                           {"i": x.hab(person).pre, "LEI": attrs["LEI"], "personLegalName": name, "officialRole": role},
                           {"auth": {**edge(auth, S.OOR_AUTH), "o": "I2I"}})

        def ecr(person: str, le_name: str, le_sad: dict, name: str, role: str) -> dict:
            return x.issue(le_name, S.ECR,
                           {"i": x.hab(person).pre, "LEI": le_sad["a"]["LEI"], "personLegalName": name,
                            "engagementContextRole": role},
                           {"le": edge(le_sad, S.LE)})

        alice = oor("alice", "le-siam", le_siam, "Alice Wattana", "Chief Executive Officer")
        erin = oor("erin", "le-andaman", le_and, "Erin Chaiyaporn", "Head of Treasury")
        bob = ecr("bob", "le-andaman", le_and, "Bob Srisuk", "Portfolio Manager")
        carol = ecr("carol", "le-andaman", le_and, "Carol Rattana", "Trader")
        x.revoke(carol["d"])  # TEL revocation before verification

        # Dave's OOR is signed with the QVI's *pre-rotation* key, then the QVI rotates.
        dave = oor("dave", "le-siam", le_siam, "Dave Thongchai", "Chief Financial Officer")
        x.sign(dave["d"])
        x.hab("test-qvi").rotate()

        # ---------------- rogue ecosystem (not anchored to pinned root) ----------------
        for n in ("rogue-root", "rogue-qvi", "le-phantom", "mallory"):
            x.hab(n)
        r_qvi = x.issue("rogue-root", S.QVI, {"i": x.hab("rogue-qvi").pre, "LEI": LEI_QVI})
        r_le = x.issue("rogue-qvi", S.LE, {"i": x.hab("le-phantom").pre, "LEI": LEI_PHANTOM,
                                           "legalName": "Phantom Holdings Ltd."}, {"qvi": edge(r_qvi, S.QVI)})
        mallory_attrs = {"AID": x.hab("mallory").pre, "LEI": LEI_PHANTOM, "personLegalName": "Mallory Fake",
                         "officialRole": "Chief Executive Officer"}
        r_auth = x.issue("le-phantom", S.OOR_AUTH, {"i": x.hab("rogue-qvi").pre, **mallory_attrs},
                         {"le": edge(r_le, S.LE)})
        mallory = x.issue("rogue-qvi", S.OOR, {"i": x.hab("mallory").pre, "LEI": LEI_PHANTOM,
                                                "personLegalName": "Mallory Fake",
                                                "officialRole": "Chief Executive Officer"},
                          {"auth": {**edge(r_auth, S.OOR_AUTH), "o": "I2I"}})

        # Sign everything else with *current* keys.
        for said, c in x.creds.items():
            if c["signature"] is None:
                x.sign(said)

        # ---------------- export watcher data ----------------
        for name, hab in x.habs.items():
            (WATCHER / "kel" / f"{hab.pre}.cesr").write_bytes(bytes(hab.replay()))
        for said, events in x.tel.items():
            (WATCHER / "tel" / f"{said}.json").write_text(json.dumps(events, indent=2))

        def chain_of(leaf: dict) -> list[dict]:
            out, todo = [], [leaf["d"]]
            while todo:
                s = todo.pop()
                c = x.creds[s]
                out.append({"sad": c["sad"], "signature": c["signature"]})
                for k, e in (c["sad"].get("e") or {}).items():
                    if isinstance(e, dict) and "n" in e:
                        todo.append(e["n"])
            return out

        personas = [
            ("alice", alice, "Siam Tokenized Treasury Co., Ltd.", "Issuer CEO — may create pools", "valid"),
            ("bob", bob, "Andaman Capital Partners Ltd.", "Investor (ECR) — may buy / hold", "valid"),
            ("erin", erin, "Andaman Capital Partners Ltd.", "OOR, non-officer role — may buy, not launch", "valid"),
            ("carol", carol, "Andaman Capital Partners Ltd.", "ECR revoked in TEL — rejected", "revoked"),
            ("dave", dave, "Siam Tokenized Treasury Co., Ltd.", "Signed with rotated QVI key — rejected", "stale-key"),
            ("mallory", mallory, "Phantom Holdings Ltd.", "Chain anchored to a non-pinned root — rejected", "rogue-root"),
        ]
        for pid, leaf, entity, blurb, scenario in personas:
            (WALLETS / f"{pid}.json").write_text(json.dumps({
                "id": pid,
                "habName": pid,
                "aid": x.hab(pid).pre,
                "personLegalName": leaf["a"]["personLegalName"],
                "entity": entity,
                "lei": leaf["a"]["LEI"],
                "credentialType": S.NAMES[leaf["s"]],
                "role": leaf["a"].get("officialRole") or leaf["a"].get("engagementContextRole"),
                "description": blurb,
                "scenario": scenario,
                "leafSaid": leaf["d"],
                "credentials": chain_of(leaf),
            }, indent=2))

        (DATA_DIR / "root.json").write_text(json.dumps({"aid": root.pre, "name": "test-gleif-root",
                                                        "note": "TEST root generated with keripy, not GLEIF"}, indent=2))
        print(f"pinned root AID : {root.pre}")
        print(f"rogue root AID  : {x.hab('rogue-root').pre}")
        print(f"credentials     : {len(x.creds)}  (carol revoked, dave stale-key, mallory rogue root)")
        for pid, leaf, *_ in personas:
            print(f"  {pid:8s} {S.NAMES[leaf['s']]:4s} {leaf['a']['LEI']}  {x.hab(pid).pre}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--force", action="store_true")
    build(ap.parse_args().force)
