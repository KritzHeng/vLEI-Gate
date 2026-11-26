#!/usr/bin/env python
"""vLEI-Gate FULL journey on the REAL BSC Testnet (chainId 97) with Flap's mock USDT as the quote:
launch (token ...7777, graduated), claim, gated dividend vault yield, revocation + eviction.

Uses the v2 USDT factories from contracts/deployments/97-usdt.json (VAULT launcher factory, so the tax goes to the
gated VLEIDividendVaultV2) and the funded keys in the repo-root .env. Reuses scripts/testnet_partial.py for RPC,
key handling (keys stay in-process, never printed / logged / written), simulate-then-send tx helper and the backend
(uvicorn on a TEMP COPY of backend/data) + verifier flow. Mirrors contracts/test/fork/VLEIUsdt.BSCTest.fork.t.sol.

Flow (every write is simulated first; any unexpected result stops the run):
   0. top up wallets from the deployer only if below the minimum needed
   1. deployer mints mock USDT: alice 1,500, bob 2,000, erin 1,000, outsider 500
   2. alice (OOR CEO), bob (ECR), erin (OOR) verified + registered (skipped when registry.isActive)
   3. alice Portal.newLauncher(vaultLauncherFactory, VLEIMintConfig) target 3,000 USDT, cap 2,000 per entity
   4. outsider approve + contribute() -> real failed tx (NotVerified)
   5. bob approve 1,500 + contribute; erin approve 1,000 + contribute (entity cap: gets 500); erin again -> real
      failed tx (EntityCapReached); alice approve 1,000 + contribute (gas 9M) -> launch (FlapTokenGraduated)
   6. bob, erin, alice claim and stake in the vault (>= HELD_RELEASE_MIN_STAKE)
   7. outsider (unverified) buys / sells on the DEX until the tax is liquidated, then TaxProcessor.dispatch()
   8. admin revokeWallet(erin); erin vault.claim() -> real failed tx (NotVerified); bob evict(erin)
   9. bob vault.claim() (USDT yield); outsider stake -> real failed tx (NotVerified)
  10. outsider transfers 1 token to the deployer (token not gated: known limitation)

Resumable: progress is read back from the chain and from logs/testnet/testnet_full_usdt_97.json (no keys in it).
Rehearsal: point FULL_RPC at an anvil fork of BNB Testnet; detected via web3_clientVersion, the state goes to a
separate *.rehearsal.json file and the 601 s wait before trading is skipped with evm_increaseTime.

Run:  backend/.venv/bin/python scripts/testnet_full_usdt.py
Env:  FULL_RPC (optional override, e.g. an anvil fork), TESTNET_RPC, TESTNET_API_PORT
"""
from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

from eth_abi import encode as abi_encode
from eth_utils import keccak, to_checksum_address

sys.path.insert(0, str(Path(__file__).resolve().parent))
import testnet_partial as tp  # noqa: E402
from e2e_local import CONFIG_T, PORTAL, failed_check, first_int, mine_salt, predict_token, sel  # noqa: E402
from testnet_partial import ADDR, Backend, Stop, calldata, call, eth, register, send, step, verify_persona  # noqa: E402

REPO = tp.REPO
DEP = json.loads((REPO / "contracts" / "deployments" / "97-usdt.json").read_text())
assert DEP["chainId"] == 97 and DEP["portal"].lower() == PORTAL.lower()
REGISTRY = DEP["registry"]
VFACTORY = DEP["vaultLauncherFactory"]
VAULT_FACTORY = DEP["vaultFactory"]
USDT = DEP["quoteToken"]
ROUTER = "0xc9D63ddCB9549578057EAB6A83a543DdFEE2b8c3"  # as in the fork test
assert REGISTRY.lower() == tp.REGISTRY.lower()

E18 = 10**18
TARGET = 3_000 * E18
CAP = 2_000 * E18
SALE_DURATION = 86_400
MINT = {"alice": 1_500 * E18, "bob": 2_000 * E18, "erin": 1_000 * E18, "outsider": 500 * E18}
APPROVE = {"bob": 1_500 * E18, "erin": 1_000 * E18}
LAUNCH_GAS = 9_000_000
FAIL_GAS = 300_000
TRADE_WAIT = 601            # the fork test warps 601 s after launch before trading
MAX_ROUNDS = 60             # sell/buy rounds (fork test: up to 80)
MIN_BAL = {"alice": 8 * 10**15, "bob": 3 * 10**15, "erin": 3 * 10**15, "outsider": 3 * 10**15}
TOPUP_TO = {"alice": 12 * 10**15, "bob": 5 * 10**15, "erin": 5 * 10**15, "outsider": 5 * 10**15}
UINT_MAX = str(2**256 - 1)

GRADUATED_TOPIC = "0x" + keccak(text="FlapTokenGraduated(address)").hex()
LAUNCHFAILED_TOPIC = "0x" + keccak(text="LaunchFailed(bytes)").hex()
EVICTED_TOPIC = "0x" + keccak(text="Evicted(address,address,uint256,uint256)").hex()
VCLAIMED_TOPIC = "0x" + keccak(text="Claimed(address,uint256)").hex()

tp.ERRORS.update({sel(s): s for s in (
    "EntityCapReached(uint256,uint256)", "NoAllowance()", "NoQuoteBalance()", "UnexpectedNativeValue(uint256)",
    "InsufficientLaunchGas(uint256,uint256)", "NothingToClaim()", "NotEvictable(address)", "EntityMismatch()",
    "BelowMinStake(uint256,uint256)", "InsufficientStake(uint256,uint256)", "ZeroAmount()", "LaunchInProgress()",
    "AlreadyLaunched()", "DistributionNotInitialized()", "SaleIsCancelled()", "QuoteTransferMismatch(uint256,uint256)",
    "VaultQuoteMismatch()", "LaunchLiquidityTooLow()")})

REHEARSAL = False


def setup_rpc() -> None:
    global REHEARSAL
    if os.getenv("FULL_RPC"):
        tp.RPC = os.environ["FULL_RPC"]
        if int(tp.rpc("eth_chainId", []), 16) != 97:
            raise Stop("FULL_RPC is not chainId 97")
    else:
        tp.pick_rpc()
    REHEARSAL = "anvil" in str(tp.rpc("web3_clientVersion", [])).lower()
    if REHEARSAL:  # anvil suggests 1 gwei; price txs like the real chain (0.1 gwei) so balances behave the same
        _rpc = tp.rpc
        tp.rpc = lambda m, p, **kw: hex(10**8) if m == "eth_gasPrice" else _rpc(m, p, **kw)
    name = "testnet_full_usdt_97" + (".rehearsal" if REHEARSAL else "") + ".json"
    tp.STATE_FILE = REPO / "logs" / "testnet" / name
    tp.state = json.loads(tp.STATE_FILE.read_text()) if tp.STATE_FILE.exists() else {"txs": []}


def S() -> dict:
    return tp.state


def save() -> None:
    tp.save_state()


def u(to: str, sig: str, *args: str) -> int:
    return first_int(call(to, sig, *args))


def usdt_of(a: str) -> int:
    return u(USDT, "balanceOf(address)(uint256)", a)


def now_ts() -> int:
    return int(tp.rpc("eth_getBlockByNumber", ["latest", False])["timestamp"], 16)


def done(key: str) -> bool:
    return key in S().setdefault("done", {})


def mark(key: str, value="ok") -> None:
    S().setdefault("done", {})[key] = value
    save()


def note(text: str) -> None:
    S()["txs"][-1]["note"] = text
    save()
    print(f"     -> {text}")


def tx(who, to, data, *, label, value=0, expect_revert=None, gas=None) -> dict:
    return send(who, to, data, value, label=label, expect_revert=expect_revert, gas=gas)


def hx(v: int) -> str:
    return f"{v / E18:,.6f}"


# ------------------------------------------------------------------ steps


def step0_funds() -> None:
    step("0. gas balances (top up from the deployer only when below the minimum)")
    for n, mn in MIN_BAL.items():
        have = tp.balance(ADDR[n])
        if have >= mn:
            print(f"     {n} {eth(have)} tBNB: ok")
            continue
        tx("deployer", ADDR[n], "0x", label=f"fund {n} {eth(TOPUP_TO[n] - have)} tBNB", value=TOPUP_TO[n] - have)


def step1_mint() -> None:
    step("1. mint mock USDT (deployer calls mint(address,uint256))")
    for n, amt in MINT.items():
        if done(f"mint:{n}"):
            print(f"     {n} already minted: skip (balance {hx(usdt_of(ADDR[n]))})")
            continue
        tx("deployer", USDT, calldata("mint(address,uint256)", ADDR[n], str(amt)), label=f"mint {amt // E18} USDT to {n}")
        mark(f"mint:{n}")
        print(f"     {n} USDT {hx(usdt_of(ADDR[n]))}")


def step2_verify() -> None:
    step("2. verify + register alice (launch), bob (invest), erin (invest)")
    need = [w for w in ("alice", "bob", "erin") if call(REGISTRY, "isActive(address)(bool)", ADDR[w]) != "true"]
    if need:
        with Backend() as api:
            for who in need:
                action = "launch" if who == "alice" else "invest"
                res = verify_persona(who, who, action, api)
                if not (res["ok"] and (res["role"] == 3 if who == "alice" else res["role"] >= 1)):
                    raise Stop(f"verify {who} {action}: {failed_check(res)} {res}")
                print(f"     {who}: verifier ok, role {res['role']} ({res['role_name']})")
                register(res, who, f"{who} register ({action})")
    for who in ("alice", "bob", "erin"):
        exp_ok = call(REGISTRY, "isActive(address)(bool)", ADDR[who]) == "true"
        print(f"     {who}: isActive {exp_ok}, leiHash {call(REGISTRY, 'leiHashOf(address)(bytes32)', ADDR[who])[:18]}…, "
              f"walletRevoked {call(REGISTRY, 'walletRevoked(address)(bool)', ADDR[who])}")
        if not exp_ok:
            raise Stop(f"{who} not active after registration")
    if call(REGISTRY, "canLaunch(address)(bool)", ADDR["alice"]) != "true":
        raise Stop("canLaunch(alice) false")
    lb, le, la = (call(REGISTRY, "leiHashOf(address)(bytes32)", ADDR[w]) for w in ("bob", "erin", "alice"))
    if lb != le or la == lb:
        raise Stop("expected bob and erin in one entity, alice in another")
    S()["leiHash"] = {"alice": la, "andaman": lb}
    save()


def launcher_data(salt: bytes) -> str:
    cfg = ("vLEI Demo Treasury", "VLDT", "", salt, TARGET, SALE_DURATION, CAP)
    return "0x" + abi_encode([CONFIG_T], [cfg]).hex()


def step3_launcher() -> str:
    step("3. alice Portal.newLauncher(VLEIVaultLauncherFactoryV2, VLEIMintConfig) with a 0x7777 salt")
    if S().get("launcher"):
        launcher = S()["launcher"]
        print(f"     launcher {launcher} (from state): skip")
    else:
        t0 = time.time()
        salt = mine_salt(f"testnet-usdt-{ADDR['alice']}-{time.time()}".encode())
        token = predict_token(salt)
        print(f"     salt 0x{salt.hex()} -> token {token} ({time.time() - t0:.1f}s)")
        if not token.lower().endswith("7777"):
            raise Stop("mined salt does not give a ...7777 token")
        fee = u(PORTAL, "SALT_LOCK_FEE()(uint256)")
        if fee != 5 * 10**15:
            raise Stop(f"SALT_LOCK_FEE is {fee}, expected 0.005")
        launcher = to_checksum_address(call(VFACTORY, "predictLauncher(address,bytes32)(address)", ADDR["alice"],
                                            "0x" + salt.hex()))
        S().update({"salt": "0x" + salt.hex(), "predictedToken": token, "launcherPredicted": launcher})
        save()
        tx("alice", PORTAL, calldata("newLauncher(address,bytes)", VFACTORY, launcher_data(salt)),
           label="alice Portal.newLauncher(vaultLauncherFactory)", value=fee)
        S()["launcher"] = launcher
        save()
        note(f"launcher {launcher}")
    checks = {
        "isLauncher": call(VFACTORY, "isLauncher(address)(bool)", launcher) == "true",
        "quoteToken": call(launcher, "quoteToken()(address)").lower() == USDT.lower(),
        "vaultFactory": call(launcher, "vaultFactory()(address)").lower() == VAULT_FACTORY.lower(),
        "creator": call(launcher, "creator()(address)").lower() == ADDR["alice"].lower(),
        "target": u(launcher, "targetRaise()(uint256)") == TARGET,
    }
    if not all(checks.values()):
        raise Stop(f"launcher checks failed: {checks}")
    print(f"     launcher {launcher}: {', '.join(checks)} ok; status {u(launcher, 'status()(uint8)')}, deadline "
          f"{u(launcher, 'saleDeadline()(uint256)')}")
    return launcher


def approve(who: str, spender: str, amount: int, label: str, token: str = USDT) -> None:
    if u(token, "allowance(address,address)(uint256)", ADDR[who], spender) >= amount:
        print(f"     {who} allowance already >= {hx(amount)}: skip approve")
        return
    tx(who, token, calldata("approve(address,uint256)", spender, str(amount)), label=label)


def step4_outsider(launcher: str) -> None:
    step("4. outsider (unverified) approve + contribute() -> real failed tx (NotVerified)")
    if done("outsiderContribute"):
        print("     already recorded: skip")
        return
    approve("outsider", launcher, MINT["outsider"], "outsider approve 500 USDT to launcher")
    tx("outsider", launcher, calldata("contribute()"), label="outsider contribute()", expect_revert="NotVerified()",
       gas=FAIL_GAS)
    mark("outsiderContribute")


def contrib(launcher: str, who: str) -> int:
    return u(launcher, "contributionOf(address)(uint256)", ADDR[who])


def step5_contribute(launcher: str) -> None:
    step("5. bob 1,500 + erin (entity cap) + alice launches")
    if call(launcher, "launched()(bool)") != "true":
        for who in ("bob", "erin"):
            if contrib(launcher, who):
                print(f"     {who} contributed {hx(contrib(launcher, who))}: skip")
                continue
            approve(who, launcher, APPROVE[who], f"{who} approve {APPROVE[who] // E18} USDT to launcher")
            before = usdt_of(ADDR[who])
            prev = u(launcher, "previewContribute(address)(uint256)", ADDR[who])
            tx(who, launcher, calldata("contribute()"), label=f"{who} contribute()")
            pulled = before - usdt_of(ADDR[who])
            note(f"pulled {hx(pulled)} USDT (previewContribute said {hx(prev)}); raised "
                 f"{hx(u(launcher, 'raised()(uint256)'))}")
        if not done("erinCapRevert"):
            print(f"     erin remaining allowance {hx(u(USDT, 'allowance(address,address)(uint256)', ADDR['erin'], launcher))}, "
                  f"remainingCapUsd {hx(u(launcher, 'remainingCapUsd(address)(uint256)', ADDR['erin']))}")
            tx("erin", launcher, calldata("contribute()"), label="erin contribute() again (entity cap)",
               expect_revert="EntityCapReached", gas=FAIL_GAS)
            note("reverted EntityCapReached(2000e18, 2000e18): Andaman entity (bob + erin) at its 2,000 USDT cap")
            mark("erinCapRevert")
        left = TARGET - u(launcher, "raised()(uint256)")
        print(f"     raised {hx(TARGET - left)}, still needed {hx(left)}")
        approve("alice", launcher, left, f"alice approve {left // E18} USDT to launcher")
        rec = tx("alice", launcher, calldata("contribute()"), label="alice contribute() -> launch", gas=LAUNCH_GAS)
        logs = rec["logs"]
        graduated = any(lg["address"].lower() == PORTAL.lower() and lg["topics"][0] == GRADUATED_TOPIC for lg in logs)
        failed = any(lg["topics"][0] == LAUNCHFAILED_TOPIC and lg["address"].lower() == launcher.lower() for lg in logs)
        S().update({"graduated": graduated, "launchFailed": failed, "launchBlock": int(rec["blockNumber"], 16),
                    "launchTx": rec["transactionHash"]})
        save()
        if failed or call(launcher, "launched()(bool)") != "true":
            raise Stop("launch failed (LaunchFailed emitted or launched() false)")
        note(f"launched; gasUsed {int(rec['gasUsed'], 16)}; FlapTokenGraduated {'emitted' if graduated else 'NOT emitted'}")
    token = to_checksum_address(call(launcher, "token()(address)"))
    vault = to_checksum_address(call(launcher, "vault()(address)"))
    pv, vf = call(PORTAL, "getLaunchVault(address)(address,address)", token).split("\n")
    pool = call(launcher, "pool()(address)")
    if not token.lower().endswith("7777") or token != S().get("predictedToken", token):
        raise Stop(f"token {token} does not match the ...7777 prediction")
    if pv.lower() != vault.lower() or vf.lower() != VAULT_FACTORY.lower():
        raise Stop(f"Portal.getLaunchVault mismatch: {pv} {vf}")
    if call(vault, "quoteToken()(address)").lower() != USDT.lower():
        raise Stop("vault quote is not USDT")
    S().update({"token": token, "vault": vault, "pool": pool,
                "contributions": {w: str(contrib(launcher, w)) for w in ("alice", "bob", "erin")}})
    save()
    print(f"     token {token}\n     vault {vault}\n     pool  {pool}\n     contributions " +
          ", ".join(f"{w} {hx(int(v))}" for w, v in S()["contributions"].items()) +
          f"; launcher USDT left {hx(usdt_of(launcher))}; graduated {S().get('graduated')}")


def step6_claim_stake(launcher: str) -> None:
    step("6. bob, erin, alice claim and stake in the vault")
    token, vault = S()["token"], S()["vault"]
    for who in ("bob", "erin", "alice"):
        if u(launcher, "claimableOf(address)(uint256)", ADDR[who]):
            tx(who, launcher, calldata("claim()"), label=f"{who} launcher.claim()")
            note(f"{who} token balance {hx(u(token, 'balanceOf(address)(uint256)', ADDR[who]))}")
        staked = u(vault, "stakedOf(address)(uint256)", ADDR[who])
        if staked:
            print(f"     {who} staked {hx(staked)}: skip")
            continue
        amt = u(token, "balanceOf(address)(uint256)", ADDR[who])
        if who == "alice":
            amt //= 2  # alice keeps half in her wallet
        approve(who, vault, amt, f"{who} approve tokens to vault", token=token)
        tx(who, vault, calldata("stake(uint256)", str(amt)), label=f"{who} vault.stake({hx(amt)})")
    total = u(vault, "totalStaked()(uint256)")
    print(f"     vault totalStaked {hx(total)} (HELD_RELEASE_MIN_STAKE {hx(u(vault, 'HELD_RELEASE_MIN_STAKE()(uint256)'))})")
    if total < 10_000 * E18:
        raise Stop("total stake below HELD_RELEASE_MIN_STAKE")


def liquidated(proc: str) -> bool:
    return any(u(proc, f"{f}()(uint256)") for f in (
        "feeQuoteBalance", "marketQuoteBalance", "pendingDividendQuoteTokenBalance", "lpQuoteBalance"))


def swap(frm: str, to: str, amount: int, label: str) -> None:
    deadline = str(now_ts() + 600)
    data = calldata("swapExactTokensForTokensSupportingFeeOnTransferTokens(uint256,uint256,address[],address,uint256)",
                    str(amount), "0", f"[{frm},{to}]", ADDR["outsider"], deadline)
    tx("outsider", ROUTER, data, label=label)


def step7_trade_dispatch() -> None:
    step("7. outsider (unverified) trades on the DEX, tax is liquidated, TaxProcessor.dispatch()")
    token, vault = S()["token"], S()["vault"]
    proc = to_checksum_address(call(token, "taxProcessor()(address)"))
    S()["taxProcessor"] = proc
    if done("dispatch"):
        print("     dispatch already done: skip")
        return
    launch_ts = int(tp.rpc("eth_getBlockByNumber", [hex(S()["launchBlock"]), False])["timestamp"], 16)
    wait = launch_ts + TRADE_WAIT - now_ts()
    if wait > 0:
        if REHEARSAL:
            tp.rpc("evm_increaseTime", [wait + 1])
            tp.rpc("evm_mine", [])
        else:
            print(f"     waiting {wait}s (launch + {TRADE_WAIT}s, as the fork test's vm.warp)", flush=True)
            time.sleep(wait + 3)
    if "vaultUsdtBefore" not in S():
        S()["vaultUsdtBefore"] = str(usdt_of(vault))
        S()["vaultRevenueBefore"] = str(u(vault, "totalRevenue()(uint256)"))
        save()
    approve("outsider", ROUTER, 2**255, "outsider approve USDT to router")
    approve("outsider", ROUTER, 2**255, "outsider approve token to router", token=token)
    if not done("initialBuy"):
        amt = usdt_of(ADDR["outsider"])
        swap(USDT, token, amt, f"outsider buy: {hx(amt)} USDT -> token")
        mark("initialBuy")
        note(f"outsider token balance {hx(u(token, 'balanceOf(address)(uint256)', ADDR['outsider']))}")
    rounds = S().setdefault("rounds", 0)
    while not liquidated(proc):
        if rounds >= MAX_ROUNDS:
            raise Stop(f"tax not liquidated after {rounds} rounds")
        rounds += 1
        sell = u(token, "balanceOf(address)(uint256)", ADDR["outsider"]) * 30 // 100
        if sell == 0:
            raise Stop("outsider has no tokens to sell")
        before = usdt_of(ADDR["outsider"])
        swap(token, USDT, sell, f"outsider sell #{rounds}: 30% tokens")
        proceeds = usdt_of(ADDR["outsider"]) - before
        print(f"     proceeds {hx(proceeds)} USDT; liquidated {liquidated(proc)}; processor token bal "
              f"{hx(u(token, 'balanceOf(address)(uint256)', proc))}")
        if proceeds > 0 and not liquidated(proc):
            swap(USDT, token, proceeds * 90 // 100, f"outsider buy #{rounds}: 90% of proceeds")
        S()["rounds"] = rounds
        save()
    bals = {f: u(proc, f"{f}()(uint256)") for f in (
        "feeQuoteBalance", "marketQuoteBalance", "pendingDividendQuoteTokenBalance", "lpQuoteBalance")}
    print(f"     liquidated after {rounds} rounds: " + ", ".join(f"{k} {hx(v)}" for k, v in bals.items()))
    S()["processorBeforeDispatch"] = {k: str(v) for k, v in bals.items()}
    rev0 = int(S().get("vaultRevenueBefore", 0))
    pre = u(vault, "totalRevenue()(uint256)") - rev0  # a Flap keeper (batchDispatch) may have dispatched already
    tx("outsider", proc, calldata("dispatch()"), label="TaxProcessor.dispatch() (by outsider)")
    arrived = usdt_of(vault) - int(S()["vaultUsdtBefore"])
    recognized = u(vault, "totalRevenue()(uint256)") - rev0
    if arrived <= 0:
        raise Stop("no USDT reached the vault")
    S().update({"vaultUsdtArrived": str(arrived), "vaultRevenueRecognized": str(recognized)})
    note(f"USDT arrived at the vault {hx(arrived)}; recognized (totalRevenue) {hx(recognized)}"
         + (f", of which {hx(pre)} before our dispatch (keeper)" if pre else ""))
    mark("dispatch")


def step8_revoke_evict() -> None:
    step("8. revokeWallet(erin); erin vault.claim() -> NotVerified; bob evicts erin")
    token, vault = S()["token"], S()["vault"]
    S()["pendingBeforeRevoke"] = {w: str(u(vault, "pendingRewards(address)(uint256)", ADDR[w])) for w in ("alice", "bob", "erin")}
    save()
    if call(REGISTRY, "walletRevoked(address)(bool)", ADDR["erin"]) != "true":
        tx("deployer", REGISTRY, calldata("revokeWallet(address,string)", ADDR["erin"], "demo: TEL revocation"),
           label="admin revokeWallet(erin)")
    if not done("erinClaimRevert"):
        tx("erin", vault, calldata("claim()"), label="erin vault.claim()", expect_revert="NotVerified()", gas=FAIL_GAS)
        mark("erinClaimRevert")
    if u(vault, "stakedOf(address)(uint256)", ADDR["erin"]):
        pend = u(vault, "pendingRewards(address)(uint256)", ADDR["erin"])
        tb = u(token, "balanceOf(address)(uint256)", ADDR["erin"])
        rec = tx("bob", vault, calldata("evict(address)", ADDR["erin"]), label="bob vault.evict(erin)")
        ev = next(lg for lg in rec["logs"] if lg["topics"][0] == EVICTED_TOPIC)
        data = bytes.fromhex(ev["data"][2:])
        returned, forfeited = int.from_bytes(data[:32], "big"), int.from_bytes(data[32:64], "big")
        delta = u(token, "balanceOf(address)(uint256)", ADDR["erin"]) - tb
        S()["evict"] = {"returned": str(returned), "forfeited": str(forfeited), "erinTokenDelta": str(delta),
                        "erinPendingBefore": str(pend)}
        note(f"erin's {hx(returned)} tokens returned (balance +{hx(delta)}); {hx(forfeited)} USDT rewards forfeited "
             f"to the remaining stakers (pending before {hx(pend)})")
    print(f"     vault totalForfeited {hx(u(vault, 'totalForfeited()(uint256)'))}, totalStaked "
          f"{hx(u(vault, 'totalStaked()(uint256)'))}")


def step9_bob_claim_outsider_stake() -> None:
    step("9. bob vault.claim() (USDT yield); outsider stake -> NotVerified")
    token, vault = S()["token"], S()["vault"]
    if not done("bobClaim"):
        pend = u(vault, "pendingRewards(address)(uint256)", ADDR["bob"])
        b0 = usdt_of(ADDR["bob"])
        tx("bob", vault, calldata("claim()"), label="bob vault.claim()")
        got = usdt_of(ADDR["bob"]) - b0
        S()["bobYield"] = str(got)
        note(f"bob received {hx(got)} USDT (pending was {hx(pend)})")
        mark("bobClaim")
    S()["alicePending"] = str(u(vault, "pendingRewards(address)(uint256)", ADDR["alice"]))
    save()
    print(f"     alice pending (not claimed) {hx(int(S()['alicePending']))} USDT")
    if not done("outsiderStake"):
        amt = u(token, "balanceOf(address)(uint256)", ADDR["outsider"]) // 2
        approve("outsider", vault, amt, "outsider approve tokens to vault", token=token)
        tx("outsider", vault, calldata("stake(uint256)", str(amt)), label=f"outsider vault.stake({hx(amt)})",
           expect_revert="NotVerified()", gas=FAIL_GAS)
        mark("outsiderStake")


def step10_transfer() -> None:
    step("10. outsider transfers 1 token to the deployer (token itself not gated: known limitation)")
    if done("transfer"):
        print("     already done: skip")
        return
    token = S()["token"]
    tx("outsider", token, calldata("transfer(address,uint256)", ADDR["deployer"], str(E18)),
       label="outsider token.transfer(deployer, 1)")
    mark("transfer")


def report() -> None:
    names = ("deployer", "alice", "bob", "erin", "outsider")
    end = {n: tp.balance(ADDR[n]) for n in names}
    fees = sum(t["feeWei"] for t in S()["txs"])
    paid = sum(t["valueWei"] for t in S()["txs"] if t["label"].startswith("alice Portal.newLauncher"))
    print("\n---------------- summary")
    for t in S()["txs"]:
        print(f"{t['status']:9} {t['label']:52} {t['url']}")
    print(f"token {S().get('token')}  vault {S().get('vault')}  launcher {S().get('launcher')}")
    print("balances: " + ", ".join(f"{n} {eth(v)}" for n, v in end.items()))
    print(f"gas {eth(fees)} + salt-lock fee {eth(paid)} = {eth(fees + paid)} tBNB over {len(S()['txs'])} txs")
    S()["endBalances"] = {n: str(v) for n, v in end.items()}
    S()["totals"] = {"gasWei": str(fees), "saltLockFeeWei": str(paid)}
    save()


def run() -> None:
    names = ("deployer", "alice", "bob", "erin", "outsider")
    S().setdefault("startBalances", {n: str(tp.balance(ADDR[n])) for n in names})
    save()
    step0_funds()
    step1_mint()
    step2_verify()
    launcher = step3_launcher()
    step4_outsider(launcher)
    step5_contribute(launcher)
    step6_claim_stake(launcher)
    step7_trade_dispatch()
    step8_revoke_evict()
    step9_bob_claim_outsider_stake()
    step10_transfer()
    report()


if __name__ == "__main__":
    try:
        setup_rpc()
        print(f"RPC {tp.RPC}{' (anvil rehearsal)' if REHEARSAL else ''}\nstate {tp.STATE_FILE}\n"
              f"vaultLauncherFactory {VFACTORY}\nregistry {REGISTRY}\nUSDT {USDT}\nportal {PORTAL}")
        print("wallets: " + ", ".join(f"{n} {a}" for n, a in ADDR.items()))
        run()
    except Stop as e:
        print(f"\nSTOPPED: {e}", file=sys.stderr)
        sys.exit(1)
