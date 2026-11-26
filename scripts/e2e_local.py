#!/usr/bin/env python
"""End-to-end test of vLEI-Gate on an anvil FORK of BNB Testnet (chainId 97) with the live Flap Portal.

    anvil --fork-url $BSC_TESTNET_RPC_URL -> forge Deploy.s.sol -> enable_factory_fork.sh
    -> backend (uvicorn, temp copy of backend/data) -> HTTP verifier flow -> cast txs on the Portal / launcher

Flow:
  alice (OOR CEO):  verify(launch) -> register -> Portal.newLauncher(factory, VLEIMintConfig) with a 0x7777 salt
  bob   (ECR):      verify(launch) rejected at "role"; verify(invest) -> register; Portal.newLauncher reverts
                    (CreatorNotAuthorized)
  outsider:         contribute reverts (NotVerified)
  bob + erin:       same legal entity, one per-entity USD cap (Atlas/mock feed): erin over the cap -> CapExceeded
  bob, erin, alice: contribute until targetRaise -> the last contribution launches the token on the DEX (Launched,
                    token ends in 7777)
  bob claim         -> token balance > 0; the token is freely transferable (known limitation)
  admin revokeEntity(bob's leiHash) -> erin (same entity, not yet claimed) claim reverts NotVerified
  revoke_and_push.py bob --push     -> the verifier rejects bob at "revocation"
  verifier attacks: other AID signs for alice's credential -> "holder"; mallory (non-pinned root) -> "root"

Everything runs against fresh random accounts (funded with anvil_setBalance), a temporary deployments file
(contracts/deployments/97-e2e-<pid>.json, deleted afterwards) and a temporary COPY of backend/data, so neither
deployments/97.json nor the real test chain is touched. Exits non-zero on the first failed step.

Env:
  BSC_TESTNET_RPC_URL (or BSC_TESTNET_RPC)  fork source; default https://bsc-testnet-rpc.publicnode.com
  E2E_ANVIL_PORT (18545), E2E_API_PORT (18000), FLAP_TOKEN_IMPL (Portal's tax-token implementation)
Run:  scripts/e2e_local.sh   (or backend/.venv/bin/python scripts/e2e_local.py)
"""
from __future__ import annotations

import atexit
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import httpx
from eth_abi import encode as abi_encode
from eth_account import Account
from eth_account.messages import encode_defunct
from eth_utils import keccak, to_checksum_address

REPO = Path(__file__).resolve().parent.parent
CONTRACTS = REPO / "contracts"
BACKEND = REPO / "backend"
PY = BACKEND / ".venv" / "bin" / "python"

ANVIL_PORT = int(os.getenv("E2E_ANVIL_PORT", "18545"))
API_PORT = int(os.getenv("E2E_API_PORT", "18000"))
RPC = f"http://127.0.0.1:{ANVIL_PORT}"
API = f"http://127.0.0.1:{API_PORT}"
FORK_URL = (os.getenv("BSC_TESTNET_RPC_URL") or os.getenv("BSC_TESTNET_RPC")
            or "https://bsc-testnet-rpc.publicnode.com")

PORTAL = "0x000042108465206185A077Edc3F3fd2b49060000"
TOKEN_IMPL = os.getenv("FLAP_TOKEN_IMPL", "0x7777c57ff7dc441c1715b2e36fa581c48B782222")

# Fresh accounts every run: well-known keys (anvil's defaults) may carry EIP-7702 code on a public testnet.
NAMES = ("admin", "verifier", "alice", "bob", "erin", "outsider")
KEYS = {n: "0x" + Account.create().key.hex().removeprefix("0x") for n in NAMES}
ADDR = {k: Account.from_key(v).address for k, v in KEYS.items()}

procs: list[subprocess.Popen] = []
temp_files: list[Path] = []
step_no = 0
results: list[tuple[str, str]] = []


def step(msg: str) -> None:
    global step_no
    step_no += 1
    results.append((f"[{step_no:02d}] {msg}", "FAIL"))  # flipped to PASS by done()
    print(f"\n[{step_no:02d}] {msg}", flush=True)


def done() -> None:
    if results:
        results[-1] = (results[-1][0], "PASS")


def ok(msg: str) -> None:
    print(f"     PASS  {msg}", flush=True)


class E2EFailure(Exception):
    pass


def expect(cond: bool, msg: str) -> None:
    if not cond:
        raise E2EFailure(msg)
    ok(msg)


def sel(sig: str) -> str:
    return "0x" + keccak(text=sig)[:4].hex()


def run(cmd: list[str], *, cwd: Path = REPO, env: dict | None = None, check: bool = True,
        timeout: int = 600) -> subprocess.CompletedProcess:
    env = {**os.environ, "FOUNDRY_DISABLE_NIGHTLY_WARNING": "1", **(env or {})}
    r = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True, timeout=timeout)
    if check and r.returncode != 0:
        raise E2EFailure(f"command failed ({r.returncode}): {' '.join(cmd[:4])} ...\n{r.stdout}\n{r.stderr}")
    return r


def cast_send(key: str, to: str, sig: str, *args: str, value: str | None = None, check: bool = True,
              gas: int | None = None):
    cmd = ["cast", "send", "--rpc-url", RPC, "--private-key", KEYS[key], to, sig, *args]
    if value:
        cmd += ["--value", value]
    if gas:
        cmd += ["--gas-limit", str(gas)]
    return run(cmd, check=check)


def cast_call(to: str, sig: str, *args: str) -> str:
    return run(["cast", "call", "--rpc-url", RPC, to, sig, *args]).stdout.strip()


def rpc(method: str, params: list) -> object:
    r = httpx.post(RPC, json={"jsonrpc": "2.0", "id": 1, "method": method, "params": params}, timeout=120).json()
    if "error" in r:
        raise E2EFailure(f"{method}: {r['error']}")
    return r["result"]


def reverted_with(r: subprocess.CompletedProcess, name: str, sig: str) -> bool:
    out = r.stderr + r.stdout
    return r.returncode != 0 and (name in out or sel(sig) in out)


def first_int(s: str) -> int:
    return int(s.split()[0])


def wait_http(url: str, what: str, timeout: float = 90) -> None:
    t0 = time.time()
    while time.time() - t0 < timeout:
        try:
            if url.startswith(RPC):
                r = httpx.post(url, json={"jsonrpc": "2.0", "id": 1, "method": "eth_chainId", "params": []}, timeout=5)
                r.raise_for_status()
                if "result" in r.json():
                    return
            else:
                httpx.get(url, timeout=2).raise_for_status()
                return
        except Exception:
            pass
        time.sleep(0.5)
    raise E2EFailure(f"{what} did not come up at {url}")


def cleanup() -> None:
    for p in reversed(procs):
        if p.poll() is None:
            p.send_signal(signal.SIGTERM)
            try:
                p.wait(timeout=10)
            except subprocess.TimeoutExpired:
                p.kill()
    procs.clear()
    for f in temp_files:
        f.unlink(missing_ok=True)


atexit.register(cleanup)
signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))


# ------------------------------------------------------------------ salt mining


def clone_init_code_hash(impl: str) -> bytes:
    """OpenZeppelin Clones (EIP-1167) creation code, as in Clones.predictDeterministicAddress."""
    code = bytes.fromhex("3d602d80600a3d3981f3363d3d373d3d3d363d73") + bytes.fromhex(impl[2:]) + \
        bytes.fromhex("5af43d82803e903d91602b57fd5bf3")
    return keccak(code)


def predict_token(salt: bytes, impl: str = TOKEN_IMPL, deployer: str = PORTAL) -> str:
    h = keccak(b"\xff" + bytes.fromhex(deployer[2:]) + salt + clone_init_code_hash(impl))
    return to_checksum_address(h[12:])


def mine_salt(seed: bytes) -> bytes:
    """Port of the fork test's _mineSalt: keccak(seed, i) until CREATE2(TOKEN_IMPL clone, salt, Portal) ends in 7777."""
    ich = clone_init_code_hash(TOKEN_IMPL)
    prefix = b"\xff" + bytes.fromhex(PORTAL[2:])
    seed32 = keccak(seed)
    for i in range(1, 50_000_000):
        salt = keccak(seed32 + i.to_bytes(32, "big"))
        if keccak(prefix + salt + ich)[-2:] == b"\x77\x77":
            return salt
    raise E2EFailure("no 0x7777 salt found")


# ------------------------------------------------------------------ verifier flow over HTTP


def verify_persona(persona: str, wallet_key: str, action: str, registry: str, api: httpx.Client) -> dict:
    pres = api.get(f"/api/demo/personas/{persona}/presentation").raise_for_status().json()
    wallet = ADDR[wallet_key]
    ch = api.post("/api/vlei/challenge", json={"wallet": wallet, "holder": pres["holder"]}).raise_for_status().json()
    hsig = api.post("/api/demo/agent/sign", json={"persona": persona, "message": ch["message"]}).raise_for_status().json()
    wsig = Account.from_key(KEYS[wallet_key]).sign_message(encode_defunct(text=ch["message"])).signature.hex()
    nonce = first_int(cast_call(registry, "nonces(address)(uint256)", wallet))
    return api.post("/api/vlei/verify", json={
        "challengeId": ch["id"], "leafSaid": pres["leafSaid"], "credentials": pres["credentials"],
        "holderSignature": hsig["signature"], "walletSignature": "0x" + wsig.removeprefix("0x"),
        "action": action, "registryNonce": nonce,
    }).raise_for_status().json()


def failed_check(res: dict) -> str:
    return next((c["id"] for c in res["checks"] if c["ok"] is False), "")


def register(res: dict, wallet_key: str, registry: str) -> None:
    m = res["attestation"]["message"]
    tup = f"({m['wallet']},{m['leiHash']},{m['role']},{m['nonce']},{m['expiresAt']})"
    cast_send(wallet_key, registry, "register((address,bytes32,uint8,uint256,uint64),bytes)", tup,
              res["attestation"]["signature"])


CONFIG_T = "(string,string,string,bytes32,uint256,uint256,uint256)"


def launcher_data(salt: bytes, target_wei: int, cap_usd: int) -> str:
    cfg = ("Siam T-Bill 2027", "STB27", "bafkreig4y5nwb4izyilbbmiydumvkld446d4k7j4ohg3x3q2lfel3fo4yq", salt,
           target_wei, 86400, cap_usd * 10**18)
    return "0x" + abi_encode([CONFIG_T], [cfg]).hex()


# ------------------------------------------------------------------ main


def main() -> None:
    for tool in ("anvil", "forge", "cast", "jq"):
        if not shutil.which(tool):
            raise E2EFailure(f"{tool} not found on PATH (install Foundry / jq)")
    work = Path(tempfile.mkdtemp(prefix="vlei-e2e-"))
    log_anvil = open(work / "anvil.log", "w")
    log_api = open(work / "backend.log", "w")
    print(f"work dir: {work}\nfork source: {FORK_URL}")

    # ---------------- chain ----------------
    step(f"start anvil on {RPC}, forking BNB Testnet")
    procs.append(subprocess.Popen(
        ["anvil", "--port", str(ANVIL_PORT), "--fork-url", FORK_URL, "--retries", "10", "--fork-retry-backoff", "1000",
         "--timeout", "60000", "--silent"], stdout=log_anvil, stderr=subprocess.STDOUT))
    wait_http(RPC, "anvil fork")
    expect(run(["cast", "chain-id", "--rpc-url", RPC]).stdout.strip() == "97", "fork chainId 97")
    expect(run(["cast", "code", "--rpc-url", RPC, PORTAL]).stdout.strip() not in ("", "0x"), "Flap Portal has code")
    for n in NAMES:
        rpc("anvil_setBalance", [ADDR[n], hex(100 * 10**18)])
    expect(all(run(["cast", "code", "--rpc-url", RPC, ADDR[n]]).stdout.strip() == "0x" for n in NAMES),
           "fresh accounts funded with 100 BNB, no code")
    done()

    step("deploy VLEIRegistry + MockPriceFeed + VLEIMintLauncher + VLEILauncherFactory (script/Deploy.s.sol)")
    dep_rel = f"./deployments/97-e2e-{os.getpid()}.json"
    dep_file = CONTRACTS / dep_rel
    temp_files.append(dep_file)
    dep_env = {k: v for k, v in os.environ.items() if k not in (
        "ADMIN_ADDRESS", "VERIFIER_ADDRESS", "ATLAS_FEED_ADDRESS", "MAX_PRICE_AGE", "FLAP_PORTAL", "FLAP_GUARDIAN")}
    dep_env.update({"DEPLOYER_PRIVATE_KEY": KEYS["admin"], "VERIFIER_PRIVATE_KEY": KEYS["verifier"],
                    "DEPLOYMENTS_FILE": dep_rel, "FOUNDRY_DISABLE_NIGHTLY_WARNING": "1"})
    subprocess_env_run = subprocess.run(
        ["forge", "script", "script/Deploy.s.sol", "--rpc-url", RPC, "--broadcast", "--slow"],
        cwd=CONTRACTS, env=dep_env, capture_output=True, text=True, timeout=900)
    if subprocess_env_run.returncode != 0 or not dep_file.exists():
        raise E2EFailure(f"forge script failed\n{subprocess_env_run.stdout[-3000:]}\n{subprocess_env_run.stderr[-3000:]}")
    dep = json.loads(dep_file.read_text())
    registry, factory, feed = dep["registry"], dep["factory"], dep["priceFeed"]
    print(f"     registry {registry}\n     factory  {factory}\n     feed     {feed} mock={dep['mockPriceFeed']}"
          f"\n     beacon   {dep['beacon']}\n     portal   {dep['portal']}")
    expect(dep["chainId"] == 97 and dep["portal"].lower() == PORTAL.lower(), "deployments JSON: chainId 97, Flap Portal")
    expect(dep["verifier"].lower() == ADDR["verifier"].lower(), "registry verifier = e2e verifier key")
    expect(cast_call(factory, "registry()(address)").lower() == registry.lower(), "factory.registry() = registry")
    done()

    step("enable the factory on the Portal (script/enable_factory_fork.sh impersonates the Portal admin)")
    r = run(["bash", str(CONTRACTS / "script" / "enable_factory_fork.sh"), factory, RPC])
    print("     " + r.stdout.strip().replace("\n", "\n     "))
    expect(cast_call(PORTAL, "launcherFactoryMultiplier(address)(bool,uint16)", factory).split()[0] == "true",
           "Portal.launcherFactoryMultiplier(factory).enabled == true")
    done()

    step("start backend (CHAIN_ID=97) against a temp copy of backend/data")
    data_copy = work / "data"
    shutil.copytree(BACKEND / "data", data_copy)
    root_aid = json.loads((data_copy / "root.json").read_text())["aid"]
    api_env = {
        "VLEI_DATA_DIR": str(data_copy), "CHAIN_ID": "97", "REGISTRY_ADDRESS": registry,
        "VERIFIER_PRIVATE_KEY": KEYS["verifier"], "PINNED_ROOT_AID": root_aid, "ENABLE_DEMO_AGENT": "true",
        "RPC_URL": RPC, "COURNOT_API_URL": "", "COURNOT_API_KEY": "", "CMC_API_KEY": "",
    }
    procs.append(subprocess.Popen([str(PY), "-m", "uvicorn", "app.main:app", "--port", str(API_PORT)],
                                  cwd=BACKEND, env={**os.environ, **api_env}, stdout=log_api, stderr=subprocess.STDOUT))
    wait_http(f"{API}/api/health", "backend")
    api = httpx.Client(base_url=API, timeout=120)
    h = api.get("/api/health").json()
    expect(h["chainId"] == 97 and h["registry"].lower() == registry.lower()
           and h["verifierSigner"] == ADDR["verifier"], "backend health: chain 97, registry, verifier signer")
    done()

    # ---------------- alice creates a launcher ----------------
    step("alice (OOR CEO): verify action=launch -> register on-chain")
    res = verify_persona("alice", "alice", "launch", registry, api)
    expect(res["ok"] and res["role"] == 3, f"verifier ok, role {res['role']} ({res['role_name']})")
    expect(res["attestation"].get("nonceSource") == "chain", "attestation nonce read on-chain via RPC_URL")
    register(res, "alice", registry)
    expect(cast_call(registry, "canLaunch(address)(bool)", ADDR["alice"]) == "true", "registry.canLaunch(alice)")
    done()

    step("alice: Portal.newLauncher(factory, VLEIMintConfig) with a mined 0x7777 salt")
    t0 = time.time()
    salt = mine_salt(f"e2e-{os.getpid()}-{time.time()}".encode())
    predicted_token = predict_token(salt)
    print(f"     salt 0x{salt.hex()} -> token {predicted_token} ({time.time() - t0:.1f}s)")
    expect(predicted_token.lower().endswith("7777"), "predicted token address ends in 7777")
    fee = first_int(cast_call(PORTAL, "SALT_LOCK_FEE()(uint256)"))
    # 10 BNB (~$6,000 at the mock price): the live Portal refused a 1 BNB pool (custom error 0xa32ef056(700e18,
    # 1500e18), apparently a USD floor on the pool quote) and the factory enforces minTargetUsd (default $1,600).
    target = 10 * 10**18
    cap_usd = 4500  # per legal entity; mock feed 600 USD/BNB -> 7.5 BNB per entity
    expect(int(dep.get("minTargetUsd", "0")) == 1600 * 10**18, "factory minTargetUsd $1,600")
    r = cast_send("alice", PORTAL, "newLauncher(address,bytes)", factory,
                  launcher_data(mine_salt(b"small-" + os.urandom(8)), 10**18, cap_usd), value=str(fee), check=False)
    expect(reverted_with(r, "TargetBelowMinimum", "TargetBelowMinimum(uint256,uint256)"),
           "1 BNB target ($600) -> TargetBelowMinimum")
    data = launcher_data(salt, target, cap_usd)
    cast_send("alice", PORTAL, "newLauncher(address,bytes)", factory, data, value=str(fee))
    launcher = to_checksum_address(cast_call(factory, "predictLauncher(address,bytes32)(address)", ADDR["alice"],
                                             "0x" + salt.hex()))
    print(f"     launcher {launcher}  (SALT_LOCK_FEE {fee / 1e18} BNB)")
    expect(cast_call(factory, "isLauncher(address)(bool)", launcher) == "true", "factory.isLauncher(launcher)")
    expect(cast_call(launcher, "creator()(address)").lower() == ADDR["alice"].lower(), "launcher.creator() == alice")
    expect(first_int(cast_call(launcher, "status()(uint8)")) == 0, "status Raising")
    done()

    # ---------------- bob cannot launch ----------------
    step("bob (ECR): verify action=launch is rejected by role policy; verify action=invest -> register")
    res = verify_persona("bob", "bob", "launch", registry, api)
    expect(not res["ok"] and failed_check(res) == "role", "bob launch rejected at 'role'")
    res = verify_persona("bob", "bob", "invest", registry, api)
    expect(res["ok"] and res["role"] == 1, f"verifier ok, role {res['role']} ({res['role_name']})")
    bob_lei_hash = res["lei_hash"]
    register(res, "bob", registry)
    expect(cast_call(registry, "isActive(address)(bool)", ADDR["bob"]) == "true", "registry.isActive(bob)")
    expect(cast_call(registry, "canLaunch(address)(bool)", ADDR["bob"]) == "false", "registry.canLaunch(bob) == false")
    done()

    step("bob (ECR) calls Portal.newLauncher -> must revert CreatorNotAuthorized")
    bob_data = launcher_data(mine_salt(b"bob-" + os.urandom(8)), target, cap_usd)
    r = cast_send("bob", PORTAL, "newLauncher(address,bytes)", factory, bob_data, value=str(fee), check=False)
    expect(reverted_with(r, "CreatorNotAuthorized", "CreatorNotAuthorized(address)"),
           "newLauncher reverted with CreatorNotAuthorized(bob)")
    expect(first_int(cast_call(factory, "launcherCount()(uint256)")) == 1, "factory.launcherCount() still 1")
    done()

    # ---------------- contributions ----------------
    step("unverified outsider contributes -> must revert NotVerified")
    r = cast_send("outsider", launcher, "contribute()", value="0.1ether", check=False)
    expect(reverted_with(r, "NotVerified", "NotVerified()"), "contribute reverted with NotVerified()")
    done()

    step("erin (OOR Head of Treasury, same entity as bob): verify action=invest -> register")
    res = verify_persona("erin", "erin", "invest", registry, api)
    expect(res["ok"] and res["lei_hash"] == bob_lei_hash, f"verifier ok, role {res['role_name']}, same leiHash as bob")
    register(res, "erin", registry)
    expect(cast_call(registry, "isActive(address)(bool)", ADDR["erin"]) == "true", "registry.isActive(erin)")
    done()

    step(f"per-entity USD cap (${cap_usd}, Atlas/mock 600 USD/BNB): bob 5 BNB, erin 3 BNB -> CapExceeded")
    cast_send("bob", launcher, "contribute()", value="5ether")
    expect(first_int(cast_call(launcher, "contributionOf(address)(uint256)", ADDR["bob"])) == 5 * 10**18,
           "bob contributed 5 BNB ($3,000)")
    rem = first_int(cast_call(launcher, "remainingCapUsd(address)(uint256)", ADDR["erin"]))
    expect(rem == 1500 * 10**18, "remainingCapUsd(erin) == $1,500 (shared with bob's entity)")
    r = cast_send("erin", launcher, "contribute()", value="3ether", check=False)
    expect(reverted_with(r, "CapExceeded", "CapExceeded(uint256,uint256,uint256)"), "erin 3 BNB ($1,800) -> CapExceeded")
    done()

    step("erin 2.5 BNB, alice (issuer entity) sends 3 BNB for the last 2.5 -> partial fill, target reached -> token launched on the DEX")
    cast_send("erin", launcher, "contribute()", value="2.5ether")
    expect(first_int(cast_call(launcher, "raised()(uint256)")) == 75 * 10**17, "raised 7.5 / 10 BNB (bob+erin entity at its $4,500 cap)")
    # The launching contribution needs gasleft >= MIN_LAUNCH_GAS (7M): send with an explicit 9M limit.
    alice_before = int(rpc("eth_getBalance", [ADDR["alice"], "latest"]), 16)
    cast_send("alice", launcher, "contribute()", value="3ether", gas=9_000_000)
    expect(first_int(cast_call(launcher, "contributionOf(address)(uint256)", ADDR["alice"])) == 25 * 10**17,
           "alice booked 2.5 BNB, 0.5 BNB excess refunded (ExcessRefunded)")
    spent = alice_before - int(rpc("eth_getBalance", [ADDR["alice"], "latest"]), 16)
    expect(25 * 10**17 <= spent < 26 * 10**17, f"alice spent {spent / 1e18:.4f} BNB incl. gas")
    expect(cast_call(launcher, "launchFailed()(bool)") == "false", "launchFailed() == false")
    expect(first_int(cast_call(launcher, "status()(uint8)")) == 1, "status Launched (same tx as the last contribution)")
    token = to_checksum_address(cast_call(launcher, "token()(address)"))
    pool = cast_call(launcher, "pool()(address)")
    print(f"     token {token}\n     pool  {pool}")
    expect(token.lower().endswith("7777"), "token address ends in 7777")
    expect(token == predicted_token, "token address == CREATE2 prediction from the mined salt")
    expect(int(pool, 16) != 0, "DEX pool created")
    done()

    step("bob claims -> token balance > 0")
    cast_send("bob", launcher, "claim()")
    bob_bal = first_int(cast_call(token, "balanceOf(address)(uint256)", ADDR["bob"]))
    expect(bob_bal == 250_000 * 10**18, f"bob balance {bob_bal / 1e18:,.0f} (50% of 500k claim half)")
    expect(first_int(cast_call(launcher, "claimableOf(address)(uint256)", ADDR["erin"])) == 125_000 * 10**18,
           "erin still has 125,000 to claim")
    done()

    step("the token itself is not gated: bob transfers 1 token to the unverified outsider (known limitation)")
    r = cast_send("bob", token, "transfer(address,uint256)", ADDR["outsider"], str(10**18), check=False)
    expect(r.returncode == 0, "transfer to an unverified wallet succeeds (Flap tax token, no transfer hook)")
    done()

    step("admin revokeEntity(bob's leiHash) -> erin (same entity) claim reverts NotVerified")
    cast_send("admin", registry, "revokeEntity(bytes32,string)", bob_lei_hash, "watcher: e2e entity revocation")
    expect(cast_call(registry, "isActive(address)(bool)", ADDR["erin"]) == "false", "registry.isActive(erin) == false")
    r = cast_send("erin", launcher, "claim()", check=False)
    expect(reverted_with(r, "NotVerified", "NotVerified()"), "erin claim reverted with NotVerified()")
    expect(first_int(cast_call(launcher, "claimableOf(address)(uint256)", ADDR["erin"])) == 125_000 * 10**18,
           "erin's 125,000 stay reserved in the launcher")
    expect(first_int(cast_call(launcher, "vleiStatusOf(address)(uint8)", ADDR["erin"])) == 4, "vleiStatusOf(erin) == entity revoked")
    done()

    # ---------------- verifier ----------------
    step("watcher simulation: revoke_and_push.py bob --wallet <bob> --push -> verifier rejects bob at 'revocation'")
    r = run([str(PY), "scripts/revoke_and_push.py", "bob", "--wallet", ADDR["bob"], "--push", "--rpc", RPC,
             "--registry", registry, "--admin-key", KEYS["admin"]],
            cwd=BACKEND, env={"VLEI_DATA_DIR": str(data_copy), "CHAIN_ID": "97"})
    print("     " + r.stdout.strip().replace("\n", "\n     "))
    expect(cast_call(registry, "walletRevoked(address)(bool)", ADDR["bob"]) == "true", "registry.walletRevoked(bob)")
    res = verify_persona("bob", "bob", "invest", registry, api)
    expect(not res["ok"] and failed_check(res) == "revocation", "verifier rejects bob at 'revocation'")
    res = verify_persona("alice", "alice", "launch", registry, api)
    expect(res["ok"], "alice (other issuer path) still verifies")
    done()

    step("verifier attacks: alice's credential signed by another AID -> 'holder'; mallory (non-pinned root) -> 'root'")
    pres = api.get("/api/demo/personas/alice/presentation").json()
    ch = api.post("/api/vlei/challenge", json={"wallet": ADDR["outsider"], "holder": pres["holder"]}).json()
    hsig = api.post("/api/demo/agent/sign", json={"persona": "mallory", "message": ch["message"]}).json()
    wsig = Account.from_key(KEYS["outsider"]).sign_message(encode_defunct(text=ch["message"])).signature.hex()
    res = api.post("/api/vlei/verify", json={"challengeId": ch["id"], "leafSaid": pres["leafSaid"],
                                            "credentials": pres["credentials"], "holderSignature": hsig["signature"],
                                            "walletSignature": "0x" + wsig.removeprefix("0x")}).json()
    expect(not res["ok"] and failed_check(res) == "holder", "rejected at 'holder'")
    res = verify_persona("mallory", "outsider", "launch", registry, api)
    expect(not res["ok"] and failed_check(res) == "root", "mallory rejected at 'root'")
    done()

    cleanup()
    shutil.rmtree(work, ignore_errors=True)  # kept on failure for anvil.log / backend.log


def summary() -> None:
    print("\n---------------- summary")
    for name, status in results:
        print(f"{status}  {name}")


if __name__ == "__main__":
    code = 0
    try:
        main()
        summary()
        print("\nE2E PASSED")
    except E2EFailure as e:
        summary()
        print(f"\nE2E FAILED: {e}\n(logs: anvil.log / backend.log in the work dir above)", file=sys.stderr)
        code = 1
    except Exception as e:  # unexpected error is a failure too
        summary()
        print(f"\nE2E ERROR: {type(e).__name__}: {e}", file=sys.stderr)
        code = 2
    finally:
        cleanup()
    sys.exit(code)
