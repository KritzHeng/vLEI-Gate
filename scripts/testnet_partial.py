#!/usr/bin/env python
"""vLEI-Gate on the REAL BSC Testnet (chainId 97), as far as it goes without launching.

Uses the deployed contracts (contracts/deployments/97.json) and the funded keys in the repo-root .env. Keys are
loaded from .env and only ever used in-process to sign transactions: they are never printed, logged, written to
disk or passed on a command line (transactions are signed with eth_account, not `cast send --private-key`).

Flow (each write is simulated with eth_estimateGas / eth_call first; any unexpected result stops the run):
   1. deployer funds alice / bob / erin / outsider (top-up to the target balance only)
   2. deployer refreshes MockPriceFeed to $700 (= the Portal's BNB price) when stale or different
   3. backend (uvicorn) on a TEMP COPY of backend/data, CHAIN_ID=97, RPC_URL=testnet, demo agent on
   4. alice verify(launch) -> register; bob verify(invest) -> register; erin verify(invest) -> register
   5. alice Portal.newLauncher(factory, VLEIMintConfig) with a mined 0x7777 salt, value = SALT_LOCK_FEE
   6. outsider (unverified) contribute 0.001 BNB, sent with gas 300000 -> reverted on-chain (NotVerified)
   7. bob contributes 0.1, erin 0.02 -> raised 0.12, status Raising
   8. admin revokeWallet(bob) -> bob withdrawContribution() gets 0.1 back
   9. verifier: alice's credential signed by another AID (mallory) -> rejected at "holder" (HTTP only)

The target (2.3 BNB) is NOT reached, so nothing launches. Remaining contributions (erin's) are refundable after
the sale deadline (saleDuration 3600 s): run `scripts/testnet_partial.py refund` then.

The run is resumable: steps that are already done on-chain (balance funded, wallet registered, launcher created,
contribution made, wallet revoked, ...) are skipped. State (salt, launcher, tx hashes) is kept in
logs/testnet/testnet_partial_97.json; it contains no keys.

Run:  backend/.venv/bin/python scripts/testnet_partial.py [run|refund]
Env:  TESTNET_RPC (default https://bsc-testnet-rpc.publicnode.com, fallback data-seed-prebsc-1-s1), TESTNET_API_PORT
"""
from __future__ import annotations

import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import httpx
from dotenv import dotenv_values
from eth_abi import encode as abi_encode
from eth_account import Account
from eth_account.messages import encode_defunct
from eth_utils import to_checksum_address

sys.path.insert(0, str(Path(__file__).resolve().parent))
from e2e_local import CONFIG_T, PORTAL, failed_check, first_int, mine_salt, predict_token, sel  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
BACKEND = REPO / "backend"
PY = BACKEND / ".venv" / "bin" / "python"
DEP = json.loads((REPO / "contracts" / "deployments" / "97.json").read_text())
REGISTRY, FACTORY, FEED = DEP["registry"], DEP["factory"], DEP["priceFeed"]
assert DEP["chainId"] == 97 and DEP["portal"].lower() == PORTAL.lower()

RPCS = [os.getenv("TESTNET_RPC") or "https://bsc-testnet-rpc.publicnode.com",
        "https://data-seed-prebsc-1-s1.bnbchain.org:8545"]
STATE_FILE = REPO / "logs" / "testnet" / "testnet_partial_97.json"
EXPLORER = "https://testnet.bscscan.com/tx/"

# Demo parameters
FEED_ANSWER = 70_000_000_000          # $700, 8 decimals (the Portal's BNB price)
FEED_MAX_AGE_OK = 50 * 60             # refresh when older than this (factory maxPriceAge is 3600 s)
TARGET = 23 * 10**17                  # 2.3 BNB = $1,610 >= minTargetUsd $1,600
SALE_DURATION = 3600
CAP_USD = 1000
FUNDING = {"alice": 2 * 10**16, "bob": 12 * 10**16, "erin": 3 * 10**16, "outsider": 2 * 10**15}
BOB_IN, ERIN_IN, OUTSIDER_IN = 10**17, 2 * 10**16, 10**15
MAX_GAS_PRICE = 10**9                 # stop if gas is above 1 gwei (expected 0.1 gwei)
MAX_TX_FEE = 3 * 10**15               # stop if a single tx could cost more than 0.003 BNB in gas

_env = dotenv_values(REPO / ".env")
_KEY_VARS = {"deployer": "DEPLOYER_PRIVATE_KEY", "verifier": "VERIFIER_PRIVATE_KEY",
             "alice": "DEMO_ALICE_PRIVATE_KEY", "bob": "DEMO_BOB_PRIVATE_KEY",
             "erin": "DEMO_ERIN_PRIVATE_KEY", "outsider": "DEMO_OUTSIDER_PRIVATE_KEY"}
_ACCTS = {}
for _n, _v in _KEY_VARS.items():
    if not _env.get(_v):
        sys.exit(f"{_v} missing in .env")
    _ACCTS[_n] = Account.from_key(_env[_v])
del _env
ADDR = {n: a.address for n, a in _ACCTS.items()}

ERRORS = {sel(s): s for s in (
    "NotVerified()", "IssuerNotActive()", "CapExceeded(uint256,uint256,uint256)", "StalePrice()", "InvalidPrice()",
    "CreatorNotAuthorized(address)", "TargetBelowMinimum(uint256,uint256)", "InvalidConfig()", "SaleClosed()",
    "StillVerified()", "NothingToWithdraw()", "RefundUnavailable()", "NothingToRefund()", "InvalidNonce()",
    "InvalidSigner(address)", "AttestationExpired()", "EntityIsRevoked()", "NotFactory(address)")}


class Stop(Exception):
    pass


# ------------------------------------------------------------------ RPC

RPC = ""


def pick_rpc() -> None:
    global RPC
    for url in RPCS:
        try:
            r = httpx.post(url, json={"jsonrpc": "2.0", "id": 1, "method": "eth_chainId", "params": []}, timeout=15)
            if int(r.json()["result"], 16) == 97:
                RPC = url
                return
        except Exception:
            continue
    raise Stop("no working BSC Testnet RPC")


def rpc(method: str, params: list, *, raw: bool = False):
    last = None
    for _ in range(4):
        try:
            r = httpx.post(RPC, json={"jsonrpc": "2.0", "id": 1, "method": method, "params": params}, timeout=60).json()
            if raw:
                return r
            if "error" in r:
                raise Stop(f"{method}: {decode_err(r['error'])}")
            return r["result"]
        except (httpx.HTTPError, ValueError) as e:
            last = e
            time.sleep(2)
    raise Stop(f"{method}: RPC failure {last}")


def decode_err(err: dict) -> str:
    data = err.get("data")
    if isinstance(data, dict):
        data = data.get("data")
    if isinstance(data, str) and data.startswith("0x") and len(data) >= 10:
        return f"{ERRORS.get(data[:10], data[:10])} (data {data}) {err.get('message', '')}"
    return str(err)


def cast(*args: str) -> str:
    r = subprocess.run(["cast", *args], capture_output=True, text=True, timeout=120,
                       env={**os.environ, "FOUNDRY_DISABLE_NIGHTLY_WARNING": "1"})
    if r.returncode != 0:
        raise Stop(f"cast {args[0]} failed: {r.stderr.strip()[:500]}")
    return r.stdout.strip()


def call(to: str, sig: str, *args: str) -> str:
    return cast("call", "--rpc-url", RPC, to, sig, *args)


def calldata(sig: str, *args: str) -> str:
    return cast("calldata", sig, *args)


def balance(who: str) -> int:
    return int(rpc("eth_getBalance", [who, "latest"]), 16)


def eth(wei: int) -> str:
    return f"{wei / 1e18:.6f}"


# ------------------------------------------------------------------ state / tx log

state: dict = json.loads(STATE_FILE.read_text()) if STATE_FILE.exists() else {"txs": []}


def save_state() -> None:
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    STATE_FILE.write_text(json.dumps(state, indent=2) + "\n")


def send(who: str, to: str, data: str = "0x", value: int = 0, *, label: str, expect_revert: str | None = None,
         gas: int | None = None) -> dict:
    """Simulate, sign in-process, send, wait. expect_revert: the error the simulation must show; the tx is then
    still sent with the explicit `gas` limit so the failed tx is recorded on-chain."""
    acct = _ACCTS[who]
    tx = {"from": acct.address, "to": to, "data": data, "value": hex(value)}
    sim = rpc("eth_estimateGas", [tx], raw=True)
    if expect_revert:
        msg = decode_err(sim["error"]) if "error" in sim else "estimate succeeded"
        if "error" in sim and expect_revert not in msg:  # some nodes drop revert data on estimateGas
            sim = rpc("eth_call", [tx, "latest"], raw=True)
            msg = decode_err(sim["error"]) if "error" in sim else "eth_call succeeded"
        if "error" not in sim or expect_revert not in msg:
            raise Stop(f"{label}: expected simulation revert {expect_revert}, got {msg}")
        print(f"     simulation reverts as expected: {expect_revert}")
        gas_limit = gas or 300_000
    else:
        if "error" in sim:
            raise Stop(f"{label}: simulation failed: {decode_err(sim['error'])}")
        gas_limit = gas or int(int(sim["result"], 16) * 1.3) + 10_000
    gas_price = int(rpc("eth_gasPrice", []), 16)
    if gas_price > MAX_GAS_PRICE or gas_limit * gas_price > MAX_TX_FEE:
        raise Stop(f"{label}: gas too expensive ({gas_limit} gas @ {gas_price} wei)")
    nonce = int(rpc("eth_getTransactionCount", [acct.address, "pending"]), 16)
    signed = acct.sign_transaction({"chainId": 97, "nonce": nonce, "gasPrice": gas_price, "gas": gas_limit,
                                    "to": to_checksum_address(to), "value": value, "data": data})
    h = rpc("eth_sendRawTransaction", ["0x" + signed.raw_transaction.hex().removeprefix("0x")])
    print(f"     tx {h}  ({label})", flush=True)
    rec = None
    for _ in range(120):
        rec = rpc("eth_getTransactionReceipt", [h])
        if rec:
            break
        time.sleep(2)
    if not rec:
        raise Stop(f"{label}: no receipt for {h} after 4 min")
    ok = rec["status"] == "0x1"
    fee = int(rec["gasUsed"], 16) * int(rec.get("effectiveGasPrice", hex(gas_price)), 16)
    entry = {"label": label, "from": who, "hash": h, "status": "success" if ok else "reverted",
             "expected": "revert " + expect_revert if expect_revert else "success", "gasUsed": int(rec["gasUsed"], 16),
             "feeWei": fee, "valueWei": value, "block": int(rec["blockNumber"], 16), "url": EXPLORER + h}
    state["txs"].append(entry)
    save_state()
    if ok == bool(expect_revert):
        raise Stop(f"{label}: tx {h} status {entry['status']}, expected {entry['expected']}")
    print(f"     {'success' if ok else 'reverted (as expected)'}  gasUsed {entry['gasUsed']}  fee {eth(fee)} BNB")
    rec["_entry"] = entry
    return rec


def step(msg: str) -> None:
    print(f"\n== {msg}", flush=True)


# ------------------------------------------------------------------ verifier flow (as in e2e_local.py)


def verify_persona(persona: str, wallet_key: str, action: str, api: httpx.Client) -> dict:
    pres = api.get(f"/api/demo/personas/{persona}/presentation").raise_for_status().json()
    wallet = ADDR[wallet_key]
    ch = api.post("/api/vlei/challenge", json={"wallet": wallet, "holder": pres["holder"]}).raise_for_status().json()
    hsig = api.post("/api/demo/agent/sign", json={"persona": persona, "message": ch["message"]}).raise_for_status().json()
    wsig = _ACCTS[wallet_key].sign_message(encode_defunct(text=ch["message"])).signature.hex()
    nonce = first_int(call(REGISTRY, "nonces(address)(uint256)", wallet))
    return api.post("/api/vlei/verify", json={
        "challengeId": ch["id"], "leafSaid": pres["leafSaid"], "credentials": pres["credentials"],
        "holderSignature": hsig["signature"], "walletSignature": "0x" + wsig.removeprefix("0x"),
        "action": action, "registryNonce": nonce,
    }).raise_for_status().json()


def register(res: dict, wallet_key: str, label: str) -> None:
    m = res["attestation"]["message"]
    tup = f"({m['wallet']},{m['leiHash']},{m['role']},{m['nonce']},{m['expiresAt']})"
    data = calldata("register((address,bytes32,uint8,uint256,uint64),bytes)", tup, res["attestation"]["signature"])
    send(wallet_key, REGISTRY, data, label=label)


def free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class Backend:
    def __init__(self) -> None:
        self.work = Path(tempfile.mkdtemp(prefix="vlei-testnet-"))
        self.port = int(os.getenv("TESTNET_API_PORT") or free_port())
        self.proc: subprocess.Popen | None = None

    def __enter__(self) -> httpx.Client:
        data_copy = self.work / "data"
        shutil.copytree(BACKEND / "data", data_copy)
        root_aid = json.loads((data_copy / "root.json").read_text())["aid"]
        # The verifier key is handed over in the child's environment only (never on argv or disk).
        verifier_key = "0x" + _ACCTS["verifier"].key.hex().removeprefix("0x")
        env = {**os.environ, "VLEI_DATA_DIR": str(data_copy), "CHAIN_ID": "97", "REGISTRY_ADDRESS": REGISTRY,
               "VERIFIER_PRIVATE_KEY": verifier_key, "PINNED_ROOT_AID": root_aid, "ENABLE_DEMO_AGENT": "true",
               "RPC_URL": RPC, "COURNOT_API_URL": "", "COURNOT_API_KEY": "", "CMC_API_KEY": ""}
        self.log = open(self.work / "backend.log", "w")
        self.proc = subprocess.Popen([str(PY), "-m", "uvicorn", "app.main:app", "--port", str(self.port)],
                                     cwd=BACKEND, env=env, stdout=self.log, stderr=subprocess.STDOUT)
        api = httpx.Client(base_url=f"http://127.0.0.1:{self.port}", timeout=120)
        for _ in range(180):
            try:
                h = api.get("/api/health").raise_for_status().json()
                break
            except Exception:
                if self.proc.poll() is not None:
                    raise Stop(f"backend exited, see {self.work / 'backend.log'}")
                time.sleep(0.5)
        else:
            raise Stop("backend did not start")
        if not (h["chainId"] == 97 and h["registry"].lower() == REGISTRY.lower()
                and h["verifierSigner"] == ADDR["verifier"]):
            raise Stop(f"backend health mismatch: {h}")
        print(f"     backend on :{self.port} (data copy {data_copy}), chain 97, verifier {h['verifierSigner']}")
        return api

    def __exit__(self, *exc) -> None:
        if self.proc and self.proc.poll() is None:
            self.proc.send_signal(signal.SIGTERM)
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        self.log.close()
        if exc[0] is None:
            shutil.rmtree(self.work, ignore_errors=True)
        print(f"     backend stopped{'' if exc[0] is None else f' (logs kept in {self.work})'}")


# ------------------------------------------------------------------ steps


def ensure_feed_fresh() -> None:
    _, answer, _, updated, _ = call(FEED, "latestRoundData()(uint80,int256,uint256,uint256,uint80)").split("\n")
    now = int(rpc("eth_getBlockByNumber", ["latest", False])["timestamp"], 16)
    age = now - first_int(updated)
    if first_int(answer) == FEED_ANSWER and age < FEED_MAX_AGE_OK:
        print(f"     feed ${first_int(answer) / 1e8:.0f}, {age}s old: fresh")
        return
    print(f"     feed ${first_int(answer) / 1e8:.0f}, {age}s old -> setAnswer({FEED_ANSWER})")
    send("deployer", FEED, calldata("setAnswer(int256)", str(FEED_ANSWER)), label="feed.setAnswer($700)")


def launcher_data(salt: bytes) -> str:
    cfg = ("vLEI Demo Treasury", "VLDT", "", salt, TARGET, SALE_DURATION, CAP_USD * 10**18)
    return "0x" + abi_encode([CONFIG_T], [cfg]).hex()


def totals() -> dict:
    return {n: balance(a) for n, a in ADDR.items()}


def run() -> None:
    start = totals()
    state.setdefault("startBalances", {n: str(v) for n, v in start.items()})
    print("balances: " + ", ".join(f"{n} {eth(v)}" for n, v in start.items()))

    step("1. fund demo wallets from the deployer (top-up)")
    for n, amount in FUNDING.items():
        have = balance(ADDR[n])
        if have >= amount or (n == "alice" and state.get("launcher")) or (n in ("bob", "erin") and state.get("contributed", {}).get(n)):
            print(f"     {n} has {eth(have)}: skip")
            continue
        send("deployer", ADDR[n], "0x", amount - have, label=f"fund {n} {eth(amount - have)} tBNB")

    step("2. MockPriceFeed at $700 and fresh")
    ensure_feed_fresh()

    with Backend() as api:
        step("4. verify + register (alice launch, bob invest, erin invest)")
        for who, action, role_ok in (("alice", "launch", lambda r: r == 3), ("bob", "invest", lambda r: r >= 1),
                                     ("erin", "invest", lambda r: r >= 1)):
            if call(REGISTRY, "isActive(address)(bool)", ADDR[who]) == "true":
                print(f"     {who} already active: skip")
                continue
            res = verify_persona(who, who, action, api)
            if not (res["ok"] and role_ok(res["role"])):
                raise Stop(f"verify {who} {action}: {failed_check(res)} {res}")
            print(f"     {who}: verifier ok, role {res['role']} ({res['role_name']}), nonce source "
                  f"{res['attestation'].get('nonceSource')}")
            register(res, who, f"{who} register ({action})")
        if call(REGISTRY, "canLaunch(address)(bool)", ADDR["alice"]) != "true":
            raise Stop("registry.canLaunch(alice) is false")
        bob_lei = call(REGISTRY, "leiHashOf(address)(bytes32)", ADDR["bob"])
        if call(REGISTRY, "leiHashOf(address)(bytes32)", ADDR["erin"]) != bob_lei:
            raise Stop("bob and erin have different leiHash")

        step("5. alice Portal.newLauncher(factory, VLEIMintConfig) with a 0x7777 salt")
        if state.get("launcher"):
            launcher = state["launcher"]
            print(f"     launcher {launcher} (from state): skip")
        else:
            t0 = time.time()
            salt = mine_salt(f"testnet-{ADDR['alice']}-{time.time()}".encode())
            token = predict_token(salt)
            print(f"     salt 0x{salt.hex()} -> token {token} ({time.time() - t0:.1f}s)")
            if not token.lower().endswith("7777"):
                raise Stop("mined salt does not give a ...7777 token")
            fee = first_int(call(PORTAL, "SALT_LOCK_FEE()(uint256)"))
            if fee != 5 * 10**15:
                raise Stop(f"SALT_LOCK_FEE is {fee}, expected 0.005")
            launcher = to_checksum_address(call(FACTORY, "predictLauncher(address,bytes32)(address)", ADDR["alice"],
                                                "0x" + salt.hex()))
            data = calldata("newLauncher(address,bytes)", FACTORY, launcher_data(salt))
            send("alice", PORTAL, data, fee, label="alice Portal.newLauncher")
            state.update({"launcher": launcher, "salt": "0x" + salt.hex(), "predictedToken": token})
            save_state()
        if call(FACTORY, "isLauncher(address)(bool)", launcher) != "true":
            raise Stop("factory.isLauncher(launcher) is false")
        if launcher.lower() not in call(FACTORY, "getLaunchers()(address[])").lower():
            raise Stop("launcher not in factory.getLaunchers()")
        print(f"     launcher {launcher}: isLauncher, in getLaunchers(), creator "
              f"{call(launcher, 'creator()(address)')}, status {first_int(call(launcher, 'status()(uint8)'))}, "
              f"deadline {first_int(call(launcher, 'saleDeadline()(uint256)'))}")

        step("6. outsider (unverified) contribute 0.001 -> reverted on-chain (NotVerified)")
        if any(t["label"].startswith("outsider contribute") for t in state["txs"]):
            print("     already recorded: skip")
        else:
            send("outsider", launcher, calldata("contribute()"), OUTSIDER_IN, label="outsider contribute 0.001",
                 expect_revert="NotVerified()", gas=300_000)

        step("7. bob 0.1, erin 0.02 -> raised 0.12, status Raising")
        ensure_feed_fresh()
        state.setdefault("contributed", {})
        for who, amt in (("bob", BOB_IN), ("erin", ERIN_IN)):
            if state["contributed"].get(who):
                print(f"     {who} already contributed: skip")
                continue
            send(who, launcher, calldata("contribute()"), amt, label=f"{who} contribute {eth(amt)}")
            state["contributed"][who] = True
            save_state()
        raised = first_int(call(launcher, "raised()(uint256)"))
        status = first_int(call(launcher, "status()(uint8)"))
        print(f"     raised {eth(raised)} / {eth(TARGET)}, status {status}, bnbUsdPrice "
              f"{first_int(call(launcher, 'bnbUsdPrice()(uint256)')) / 1e18}")

        step("8. admin revokeWallet(bob) -> bob withdrawContribution()")
        if call(REGISTRY, "walletRevoked(address)(bool)", ADDR["bob"]) != "true":
            send("deployer", REGISTRY, calldata("revokeWallet(address,string)", ADDR["bob"], "demo: TEL revocation"),
                 label="admin revokeWallet(bob)")
        print(f"     vleiStatusOf(bob) = {first_int(call(launcher, 'vleiStatusOf(address)(uint8)', ADDR['bob']))}")
        contrib = first_int(call(launcher, "contributionOf(address)(uint256)", ADDR["bob"]))
        if contrib:
            before = balance(ADDR["bob"])
            rec = send("bob", launcher, calldata("withdrawContribution()"), label="bob withdrawContribution")
            delta = balance(ADDR["bob"]) - before
            print(f"     bob balance delta {eth(delta)} (= {eth(contrib)} - fee {eth(rec['_entry']['feeWei'])})")
            if delta + rec["_entry"]["feeWei"] != contrib:
                raise Stop("bob's withdrawal amount does not match his contribution")
            state["bobWithdrawDeltaWei"] = str(delta)
            save_state()
        print(f"     raised now {eth(first_int(call(launcher, 'raised()(uint256)')))}, erin "
              f"{eth(first_int(call(launcher, 'contributionOf(address)(uint256)', ADDR['erin'])))} remains")

        step("9. verifier: alice's credential signed by another AID (mallory) -> rejected at 'holder'")
        pres = api.get("/api/demo/personas/alice/presentation").json()
        ch = api.post("/api/vlei/challenge", json={"wallet": ADDR["outsider"], "holder": pres["holder"]}).json()
        hsig = api.post("/api/demo/agent/sign", json={"persona": "mallory", "message": ch["message"]}).json()
        wsig = _ACCTS["outsider"].sign_message(encode_defunct(text=ch["message"])).signature.hex()
        res = api.post("/api/vlei/verify", json={"challengeId": ch["id"], "leafSaid": pres["leafSaid"],
                                                "credentials": pres["credentials"],
                                                "holderSignature": hsig["signature"],
                                                "walletSignature": "0x" + wsig.removeprefix("0x"),
                                                "action": "launch"}).json()
        if res.get("ok") or failed_check(res) != "holder":
            raise Stop(f"expected rejection at 'holder', got {res.get('ok')} {failed_check(res)}")
        detail = next(c for c in res["checks"] if c["id"] == "holder")
        print(f"     rejected at 'holder': {detail.get('detail', '')}")
        state["holderAttack"] = {"ok": res["ok"], "failedCheck": "holder", "detail": detail.get("detail", "")}
        save_state()

    report(start)


def report(start: dict) -> None:
    end = totals()
    launcher = state.get("launcher")
    held = balance(launcher) if launcher else 0
    fees = sum(t["feeWei"] for t in state["txs"])
    print("\n---------------- summary")
    for t in state["txs"]:
        print(f"{t['status']:9} {t['label']:38} {t['url']}")
    print("balances: " + ", ".join(f"{n} {eth(v)}" for n, v in end.items()) + f", launcher {eth(held)}")
    s0 = {n: int(v) for n, v in state["startBalances"].items()}
    print(f"gas fees (all txs in state) {eth(fees)}; all-wallet net change {eth(sum(end.values()) - sum(s0.values()))}"
          f" (of which {eth(held)} recoverable in the launcher)")


def refund() -> None:
    launcher = state["launcher"]
    deadline = first_int(call(launcher, "saleDeadline()(uint256)"))
    now = int(rpc("eth_getBlockByNumber", ["latest", False])["timestamp"], 16)
    if now < deadline:
        raise Stop(f"sale deadline not reached yet ({deadline - now}s left)")
    for who in ("erin", "bob", "alice"):
        if first_int(call(launcher, "contributionOf(address)(uint256)", ADDR[who])):
            send(who, launcher, calldata("refund()"), label=f"{who} refund")
    report({})


if __name__ == "__main__":
    pick_rpc()
    print(f"RPC {RPC}\nregistry {REGISTRY}\nfactory  {FACTORY}\nfeed     {FEED}\nportal   {PORTAL}")
    print("wallets: " + ", ".join(f"{n} {a}" for n, a in ADDR.items()))
    try:
        refund() if (sys.argv[1:] or ["run"])[0] == "refund" else run()
    except Stop as e:
        print(f"\nSTOPPED: {e}", file=sys.stderr)
        sys.exit(1)
