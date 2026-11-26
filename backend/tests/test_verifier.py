"""End-to-end verifier tests against the generated test chain.

Run `python scripts/make_test_chain.py --force` first.
"""
from __future__ import annotations

import warnings

warnings.filterwarnings("ignore", category=SyntaxWarning)

import pytest  # noqa: E402
from eth_account import Account  # noqa: E402
from eth_account.messages import encode_defunct, encode_typed_data  # noqa: E402

from app.config import Settings  # noqa: E402
from app.vlei import agent  # noqa: E402
from app.vlei.verifier import ChallengeStore, Verifier  # noqa: E402

REGISTRY = "0x000000000000000000000000000000000000dEaD"
VERIFIER_KEY = "0x" + "11" * 32


@pytest.fixture()
def v():
    s = Settings()
    s.registry_address = REGISTRY
    s.verifier_private_key = VERIFIER_KEY
    store = ChallengeStore(300)
    return Verifier(s, store), store


def run(v, persona: str, *, wallet_acct=None, signer_persona: str | None = None, action: str = "invest",
        tamper=None):
    verifier, store = v
    acct = wallet_acct or Account.create()
    w = agent.load_wallet(persona)
    creds = [dict(c) for c in w["credentials"]]
    if tamper:
        creds = tamper(creds)
    ch = store.issue(wallet=acct.address, holder=w["aid"], chain_id=97, registry=REGISTRY)
    hsig = agent.sign_with_persona(signer_persona or persona, ch.message)["signature"]
    wsig = acct.sign_message(encode_defunct(text=ch.message)).signature.hex()
    return verifier.verify({
        "challengeId": ch.id, "leafSaid": w["leafSaid"], "credentials": creds, "holderSignature": hsig,
        "walletSignature": "0x" + wsig.removeprefix("0x"), "action": action, "registryNonce": 0,
    }), acct


def failed(res) -> str:
    return next((c.id for c in res.checks if c.ok is False), "")


def test_alice_officer_can_launch(v):
    res, acct = run(v, "alice", action="launch")
    assert res.ok, res.error
    assert res.role == 3
    att = res.attestation
    signable = encode_typed_data(domain_data=att["domain"], message_types=att["types"], message_data=att["message"])
    assert Account.recover_message(signable, signature=att["signature"]) == Account.from_key(VERIFIER_KEY).address
    assert att["message"]["wallet"] == acct.address


def test_bob_ecr_can_invest_not_launch(v):
    res, _ = run(v, "bob")
    assert res.ok and res.role == 1
    res, _ = run(v, "bob", action="launch")
    assert not res.ok and failed(res) == "role"


def test_erin_oor_non_officer(v):
    res, _ = run(v, "erin")
    assert res.ok and res.role == 2
    res, _ = run(v, "erin", action="launch")
    assert failed(res) == "role"


def test_carol_revoked(v):
    res, _ = run(v, "carol")
    assert failed(res) == "revocation"


def test_dave_rotated_key(v):
    res, _ = run(v, "dave")
    assert failed(res) == "signatures"


def test_mallory_rogue_root(v):
    res, _ = run(v, "mallory")
    assert failed(res) == "root"


def test_stolen_credential_other_wallet(v):
    # Attacker presents Alice's credentials but cannot sign as Alice's AID.
    res, _ = run(v, "alice", signer_persona="mallory")
    assert failed(res) == "holder"


def test_tampered_credential(v):
    def tamper(creds):
        leaf = dict(creds[0])
        sad = dict(leaf["sad"])
        sad["a"] = {**sad["a"], "officialRole": "Chief Executive Officer", "personLegalName": "Someone Else"}
        leaf["sad"] = sad
        return [leaf] + creds[1:]
    res, _ = run(v, "alice", tamper=tamper)
    assert not res.ok


def test_challenge_single_use(v):
    verifier, store = v
    res, _ = run(v, "bob")
    assert res.ok
    assert verifier.verify({"challengeId": "nope"}).error


def test_le_cannot_self_issue_oor(v):
    """Regression: an LE names its own AID as 'QVI' in an OOR Auth and issues an OOR itself."""
    from app.vlei import schemas as S
    from app.vlei.acdc import make_credential

    alice = agent.load_wallet("alice")
    creds = {c["sad"]["d"]: c for c in alice["credentials"]}
    le = next(c for c in creds.values() if c["sad"]["s"] == S.LE)
    qvi = next(c for c in creds.values() if c["sad"]["s"] == S.QVI)
    le_aid = le["sad"]["a"]["i"]
    holder = alice["aid"]
    attrs = {"AID": holder, "LEI": le["sad"]["a"]["LEI"], "personLegalName": "Eve", "officialRole": "Chief Executive Officer"}
    auth = make_credential(issuer=le_aid, schema=S.OOR_AUTH, attrs={"i": le_aid, **attrs},
                           edges={"le": {"n": le["sad"]["d"], "s": S.LE}})
    oor = make_credential(issuer=le_aid, schema=S.OOR,
                          attrs={"i": holder, "LEI": attrs["LEI"], "personLegalName": "Eve",
                                 "officialRole": "Chief Executive Officer"},
                          edges={"auth": {"n": auth["d"], "s": S.OOR_AUTH, "o": "I2I"}})
    forged = [{"sad": oor, "signature": None}, {"sad": auth, "signature": None}, le, qvi]

    verifier, store = v
    acct = Account.create()
    ch = store.issue(wallet=acct.address, holder=holder, chain_id=97, registry=REGISTRY)
    res = verifier.verify({
        "challengeId": ch.id, "leafSaid": oor["d"], "credentials": forged,
        "holderSignature": agent.sign_with_persona("alice", ch.message)["signature"],
        "walletSignature": acct.sign_message(encode_defunct(text=ch.message)).signature.hex(),
        "action": "launch", "registryNonce": 0,
    })
    assert not res.ok
    assert failed(res) == "structure"
    assert "QVI" in res.error


def test_malformed_presentation_is_structure_failure(v):
    verifier, store = v
    acct = Account.create()
    bob = agent.load_wallet("bob")
    ch = store.issue(wallet=acct.address, holder=bob["aid"], chain_id=97, registry=REGISTRY)
    bad = [{"sad": {"d": bob["leafSaid"], "s": "x"}}]  # no "a" block
    res = verifier.verify({"challengeId": ch.id, "leafSaid": bob["leafSaid"], "credentials": bad,
                           "holderSignature": "", "walletSignature": ""})
    assert not res.ok and failed(res) == "structure"
