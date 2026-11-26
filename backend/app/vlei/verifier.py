"""vLEI presentation verifier.

Checks (README §7.1):
  1. root pinning           chain terminates at the pinned root AID
  2. signature validity     each credential is signed by its issuer's *current* KEL keys
  3. chain structure        edges + schemas match the vLEI shape (OOR / ECR paths)
  4. revocation             TEL of every credential in the chain is "issued" and anchored in the issuer KEL
  5. holder control         holder AID signs the challenge with its current keys
  6. wallet control         the wallet signs the same challenge (EIP-191)
  7. role policy            role authorized for the requested action
  8. attestation            EIP-712 attestation bound to chainId + registry + nonce + expiry
"""
from __future__ import annotations

import secrets
import threading
import time
from dataclasses import asdict, dataclass, field

from eth_account import Account
from eth_account.messages import encode_defunct
from keri.core import signing

from ..config import Settings
from . import schemas as S
from .acdc import said_ok, serialize
from .attest import lei_hash, sign_attestation
from .watcher import Watcher, WatcherError


class VerificationError(Exception):
    pass


# ----------------------------------------------------------------------------
# Challenges
# ----------------------------------------------------------------------------


@dataclass
class Challenge:
    id: str
    wallet: str
    holder: str
    chain_id: int
    registry: str
    nonce: str
    issued_at: int
    expires_at: int

    @property
    def message(self) -> str:
        return (
            "vLEI-Gate verification challenge\n"
            f"wallet: {self.wallet}\n"
            f"holder: {self.holder}\n"
            f"chainId: {self.chain_id}\n"
            f"registry: {self.registry}\n"
            f"nonce: {self.nonce}\n"
            f"expiresAt: {self.expires_at}"
        )


class ChallengeStore:
    def __init__(self, ttl: int):
        self.ttl = ttl
        self._items: dict[str, Challenge] = {}
        self._lock = threading.Lock()

    def issue(self, *, wallet: str, holder: str, chain_id: int, registry: str) -> Challenge:
        now = int(time.time())
        ch = Challenge(
            id=secrets.token_hex(16),
            wallet=_checksum(wallet),
            holder=holder,
            chain_id=chain_id,
            registry=_checksum(registry),
            nonce=secrets.token_hex(16),
            issued_at=now,
            expires_at=now + self.ttl,
        )
        with self._lock:
            self._gc(now)
            self._items[ch.id] = ch
        return ch

    def consume(self, cid: str) -> Challenge | None:
        """Single use: a challenge is removed on first verification attempt."""
        with self._lock:
            ch = self._items.pop(cid, None)
        if ch and ch.expires_at < time.time():
            return None
        return ch

    def _gc(self, now: int) -> None:
        for k in [k for k, v in self._items.items() if v.expires_at < now]:
            self._items.pop(k, None)


def _checksum(addr: str) -> str:
    from eth_utils import to_checksum_address

    return to_checksum_address(addr)


# ----------------------------------------------------------------------------
# Verification
# ----------------------------------------------------------------------------


@dataclass
class Check:
    id: str
    label: str
    ok: bool | None = None  # None = not run
    detail: str = ""


@dataclass
class Result:
    ok: bool
    checks: list[Check]
    holder: str = ""
    lei: str = ""
    lei_hash: str = ""
    entity_name: str = ""
    person_name: str = ""
    credential_type: str = ""
    official_role: str = ""
    role: int = S.ROLE_NONE
    role_name: str = ""
    chain: list[dict] = field(default_factory=list)
    attestation: dict | None = None
    error: str = ""

    def to_dict(self) -> dict:
        return asdict(self)


CHECK_ORDER = [
    ("root", "Root pinning"),
    ("signatures", "Credential signatures vs. latest KEL key state"),
    ("structure", "Chain structure (edges + schemas)"),
    ("revocation", "TEL status of every credential"),
    ("holder", "Holder AID controls the credential (challenge signature)"),
    ("wallet", "Wallet controls the address (challenge signature)"),
    ("role", "Role policy for requested action"),
    ("attestation", "EIP-712 attestation issued"),
]


class Verifier:
    def __init__(self, settings: Settings, challenges: ChallengeStore):
        self.s = settings
        self.challenges = challenges

    def _registry_nonce(self, challenge: Challenge, req: dict) -> int:
        """Read nonces(wallet) on-chain when RPC_URL is set; the client's value is only a fallback."""
        if self.s.rpc_url:
            return _read_registry_nonce(self.s.rpc_url, challenge.registry, challenge.wallet)
        return int(req.get("registryNonce", 0))

    def verify(self, req: dict) -> Result:
        try:
            return self._verify(req)
        except (KeyError, TypeError, ValueError, AttributeError) as e:
            checks = [Check(cid, label) for cid, label in CHECK_ORDER]
            checks[2].ok = False
            checks[2].detail = f"malformed presentation ({type(e).__name__})"
            return Result(ok=False, checks=checks, error=f"malformed presentation: {type(e).__name__}")

    def _verify(self, req: dict) -> Result:
        checks = {cid: Check(cid, label) for cid, label in CHECK_ORDER}
        result = Result(ok=False, checks=list(checks.values()))

        def fail(cid: str, detail: str) -> Result:
            checks[cid].ok = False
            checks[cid].detail = detail
            result.error = f"{checks[cid].label}: {detail}"
            return result

        def passed(cid: str, detail: str = "") -> None:
            checks[cid].ok = True
            checks[cid].detail = detail

        challenge = self.challenges.consume(req.get("challengeId", ""))
        if challenge is None:
            result.error = "unknown, used or expired challenge"
            return result
        if not self.s.pinned_root_aid:
            result.error = "verifier has no pinned root AID configured"
            return result

        creds = {c["sad"]["d"]: c for c in req.get("credentials", []) if isinstance(c, dict) and "sad" in c}
        leaf_said = req.get("leafSaid", "")
        if leaf_said not in creds:
            result.error = "leaf credential missing from presentation"
            return result

        with Watcher(self.s.watcher_dir) as w:
            # --- 3. structure (resolve chain first; other checks depend on it) ---
            try:
                chain, info = _resolve_chain(creds, leaf_said)
            except VerificationError as e:
                return fail("structure", str(e))
            result.chain = [
                {"said": c["sad"]["d"], "type": S.NAMES.get(c["sad"]["s"], "?"), "issuer": c["sad"]["i"],
                 "holder": c["sad"]["a"].get("i", "")}
                for c in chain
            ]
            result.holder = info["holder"]
            result.lei = info["lei"]
            result.lei_hash = lei_hash(info["lei"])
            result.entity_name = info.get("entity_name", "")
            result.person_name = info.get("person_name", "")
            result.credential_type = info["type"]
            result.official_role = info.get("official_role", "")

            # --- 1. root pinning ---
            top = chain[-1]["sad"]
            if top["i"] != self.s.pinned_root_aid:
                return fail("root", f"chain anchored to {top['i'][:12]}…, expected pinned root {self.s.pinned_root_aid[:12]}…")
            passed("root", f"QVI credential issued by pinned root {top['i'][:12]}…")

            # --- 2. signatures against latest key state ---
            for c in chain:
                sad = c["sad"]
                if not said_ok(sad):
                    return fail("signatures", f"SAID mismatch on {S.NAMES.get(sad['s'])} credential (tampered)")
                try:
                    ks = w.key_state(sad["i"])
                except WatcherError as e:
                    return fail("signatures", str(e))
                sig = (c.get("signature") or {}).get("cigar", "")
                if not _verify_any(ks.verfers, sig, serialize(sad)):
                    return fail(
                        "signatures",
                        f"{S.NAMES.get(sad['s'])} credential not signed by issuer's current keys (KEL sn {ks.sn}); "
                        "signature may come from a rotated key",
                    )
            structure_detail = info["path"]
            passed("signatures", f"{len(chain)} credentials verified against current KEL keys")
            passed("structure", structure_detail)

            # --- 4. revocation (TEL of every credential) ---
            for c in chain:
                sad = c["sad"]
                try:
                    tel = w.tel_state(sad["d"], sad["i"])
                except WatcherError as e:
                    return fail("revocation", str(e))
                if tel.status != "issued":
                    return fail("revocation", f"{S.NAMES.get(sad['s'])} credential {sad['d'][:12]}… is {tel.status}")
            passed("revocation", f"all {len(chain)} credentials issued and not revoked")

            # --- 5. holder control ---
            if challenge.holder != info["holder"]:
                return fail("holder", "challenge was issued for a different holder AID")
            try:
                hks = w.key_state(info["holder"])
            except WatcherError as e:
                return fail("holder", str(e))
            if not _verify_any(hks.verfers, req.get("holderSignature", ""), challenge.message.encode()):
                return fail("holder", "holder-AID signature mismatch: presenter does not control the credential's AID")
            passed("holder", f"signed by {info['holder'][:12]}… (KEL sn {hks.sn})")

        # --- 6. wallet control ---
        try:
            recovered = Account.recover_message(
                encode_defunct(text=challenge.message), signature=req.get("walletSignature", "")
            )
        except Exception:
            recovered = ""
        if recovered.lower() != challenge.wallet.lower():
            return fail("wallet", f"wallet signature recovers to {recovered or 'nothing'}, expected {challenge.wallet}")
        passed("wallet", challenge.wallet)

        # --- 7. role policy ---
        role = _role_for(info, self.s.launch_roles)
        result.role = role
        result.role_name = S.ROLE_NAMES.get(role, "")
        action = req.get("action", "invest")
        if action == "launch" and role != S.ROLE_OOR_OFFICER:
            return fail("role", f"pool creation requires an OOR with an authorized official role; got {info['type']} "
                        f"'{info.get('official_role') or info.get('engagement_role', '')}'")
        if role == S.ROLE_NONE:
            return fail("role", "no usable role")
        passed("role", f"{result.role_name} → {'create pools, buy, hold' if role == S.ROLE_OOR_OFFICER else 'buy, hold'}")

        # --- 8. attestation ---
        if not self.s.verifier_private_key or not self.s.registry_address:
            return fail("attestation", "verifier key or registry address not configured")
        expires_at = int(time.time()) + self.s.attestation_ttl
        result.attestation = sign_attestation(
            private_key=self.s.verifier_private_key,
            chain_id=challenge.chain_id,
            registry=challenge.registry,
            wallet=challenge.wallet,
            lei=info["lei"],
            role=role,
            nonce=self._registry_nonce(challenge, req),
            expires_at=expires_at,
        )
        result.attestation["nonceSource"] = "chain" if self.s.rpc_url else "client"
        passed("attestation", f"expires {time.strftime('%Y-%m-%d %H:%M UTC', time.gmtime(expires_at))}")
        result.ok = True
        return result


def _read_registry_nonce(rpc_url: str, registry: str, wallet: str) -> int:
    import httpx
    from eth_utils import keccak

    data = "0x" + keccak(text="nonces(address)")[:4].hex() + wallet.lower().removeprefix("0x").rjust(64, "0")
    r = httpx.post(rpc_url, json={"jsonrpc": "2.0", "id": 1, "method": "eth_call",
                                  "params": [{"to": registry, "data": data}, "latest"]}, timeout=10)
    r.raise_for_status()
    body = r.json()
    if "error" in body:
        raise VerificationError(f"RPC error reading nonce: {body['error']}")
    return int(body["result"], 16)


def _verify_any(verfers, cigar_qb64: str, ser: bytes) -> bool:
    if not cigar_qb64:
        return False
    try:
        cigar = signing.Cigar(qb64=cigar_qb64)
    except Exception:
        return False
    return any(v.verify(cigar.raw, ser) for v in verfers)


def _role_for(info: dict, launch_roles: list[str]) -> int:
    if info["type"] == "OOR":
        allowed = {r.lower() for r in launch_roles}
        return S.ROLE_OOR_OFFICER if info.get("official_role", "").lower() in allowed else S.ROLE_OOR
    if info["type"] == "ECR":
        return S.ROLE_ECR
    return S.ROLE_NONE


def _edge(creds: dict, sad: dict, name: str, schema: str) -> dict:
    edge = (sad.get("e") or {}).get(name)
    if not isinstance(edge, dict) or "n" not in edge:
        raise VerificationError(f"{S.NAMES.get(sad['s'])} credential has no '{name}' edge")
    if edge.get("s") != schema:
        raise VerificationError(f"'{name}' edge points to wrong schema")
    parent = creds.get(edge["n"])
    if parent is None:
        raise VerificationError(f"'{name}' edge target {edge['n'][:12]}… missing from presentation")
    if parent["sad"]["s"] != schema:
        raise VerificationError(f"'{name}' edge target has schema {parent['sad']['s'][:12]}…, expected {S.NAMES[schema]}")
    return parent


def _resolve_chain(creds: dict, leaf_said: str) -> tuple[list[dict], dict]:
    """Walk leaf → … → QVI and enforce vLEI chain rules. Returns (chain, info)."""
    leaf = creds[leaf_said]
    ls = leaf["sad"]
    la = ls["a"]
    info: dict = {"holder": la.get("i", ""), "lei": la.get("LEI", ""), "person_name": la.get("personLegalName", "")}
    if not info["holder"]:
        raise VerificationError("leaf credential has no holder (a.i)")
    if not S.lei_is_valid(info["lei"]):
        raise VerificationError(f"invalid LEI '{info['lei']}'")

    chain = [leaf]
    if ls["s"] == S.OOR:
        info["type"] = "OOR"
        info["official_role"] = la.get("officialRole", "")
        auth = _edge(creds, ls, "auth", S.OOR_AUTH)
        aa = auth["sad"]["a"]
        if ls["i"] != aa.get("i"):
            raise VerificationError("OOR not issued by the QVI named in the OOR Authorization")
        if aa.get("AID") != info["holder"]:
            raise VerificationError("OOR Authorization names a different holder AID")
        for k in ("LEI", "officialRole", "personLegalName"):
            if aa.get(k) != la.get(k):
                raise VerificationError(f"OOR and OOR Authorization disagree on {k}")
        le = _edge(creds, auth["sad"], "le", S.LE)
        if auth["sad"]["i"] != le["sad"]["a"].get("i"):
            raise VerificationError("OOR Authorization not issued by the Legal Entity")
        chain += [auth, le]
        info["path"] = "OOR ← QVI (with OOR Auth from LE) ← LE ← QVI ← root"
        info["qvi_issued_leaf"] = True
    elif ls["s"] == S.ECR:
        info["type"] = "ECR"
        info["engagement_role"] = la.get("engagementContextRole", "")
        edges = ls.get("e") or {}
        if "le" in edges:
            le = _edge(creds, ls, "le", S.LE)
            if ls["i"] != le["sad"]["a"].get("i"):
                raise VerificationError("ECR (direct path) not issued by the Legal Entity")
            chain += [le]
            info["path"] = "ECR ← LE ← QVI ← root"
        elif "auth" in edges:
            auth = _edge(creds, ls, "auth", S.ECR_AUTH)
            aa = auth["sad"]["a"]
            if ls["i"] != aa.get("i") or aa.get("AID") != info["holder"]:
                raise VerificationError("ECR not issued by the QVI named in the ECR Authorization")
            for k in ("LEI", "personLegalName", "engagementContextRole"):
                if aa.get(k) != la.get(k):
                    raise VerificationError(f"ECR and ECR Authorization disagree on {k}")
            le = _edge(creds, auth["sad"], "le", S.LE)
            if auth["sad"]["i"] != le["sad"]["a"].get("i"):
                raise VerificationError("ECR Authorization not issued by the Legal Entity")
            chain += [auth, le]
            info["path"] = "ECR ← QVI (with ECR Auth from LE) ← LE ← QVI ← root"
            info["qvi_issued_leaf"] = True
        else:
            raise VerificationError("ECR credential has neither 'le' nor 'auth' edge")
    else:
        raise VerificationError("leaf must be an OOR or ECR credential")

    le_sad = chain[-1]["sad"]
    if le_sad["a"].get("LEI") != info["lei"]:
        raise VerificationError("leaf LEI does not match Legal Entity credential LEI")
    info["entity_name"] = le_sad["a"].get("legalName", "")
    qvi = _edge(creds, le_sad, "qvi", S.QVI)
    if le_sad["i"] != qvi["sad"]["a"].get("i"):
        raise VerificationError("LE credential not issued by the QVI holding the QVI credential")
    # OOR (and ECR via authorization) must be issued by that same root-chained QVI,
    # not by any AID the LE names in an authorization credential.
    if info.get("qvi_issued_leaf") and ls["i"] != qvi["sad"]["a"].get("i"):
        raise VerificationError(f"{info['type']} issuer is not the QVI holding a root-issued QVI credential")
    chain.append(qvi)
    return chain, info
