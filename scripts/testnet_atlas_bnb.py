#!/usr/bin/env python3
"""BSC Testnet: show the Atlas BNB/USD price doing real work in the BNB-quote launch path.

Factory `VLEILauncherFactoryV2` 0x3949…48a4 prices native BNB with `AtlasSignedFeed` (feedId 633). Steps:
  0. preflight: alice canLaunch, feed fresh (< 45 min, else run push_atlas_price.py), balances
  1. alice newLauncher with a 1 BNB target (~$560 < minTargetUsd $1,600)   -> reverts TargetBelowMinimum (on-chain)
  2. alice newLauncher with a 3.2 BNB target (~$1,790), cap $10 per entity -> launcher created
  3. alice contribute 0.01 BNB (~$5.6, valued by Atlas)                   -> success, remainingCapUsd ~ $4.4
  4. alice contribute 0.01 BNB again (cumulative ~$11.2 > $10 cap)         -> reverts CapExceeded (on-chain)

Usage: backend/.venv/bin/python scripts/testnet_atlas_bnb.py   (idempotent via logs/testnet/testnet_atlas_bnb_97.json)
Keys come from .env and are never printed.
"""
from __future__ import annotations

import json
import subprocess
import sys
import time
from pathlib import Path

from eth_abi import encode as abi_encode
from eth_utils import to_checksum_address

sys.path.insert(0, str(Path(__file__).resolve().parent))
import testnet_partial as tp  # noqa: E402
from e2e_local import CONFIG_T, PORTAL, first_int, mine_salt, predict_token, sel  # noqa: E402
from testnet_partial import ADDR, Stop, call, calldata, eth, send, step  # noqa: E402

REPO = tp.REPO
DEP = json.loads((REPO / "contracts" / "deployments" / "97-atlas.json").read_text())
FACTORY = to_checksum_address("0x394928211B03Eb74a6f7061a56973F77A7fC48a4")
FEED = to_checksum_address("0x34aa570cDa23282af94aA3CE4232bD4B18B644d5")
E18 = 10**18
LOW_TARGET = 1 * E18
TARGET = 32 * E18 // 10
CAP_USD = 10 * E18
SALE_DURATION = 7 * 86_400
CONTRIB = 10**16  # 0.01 BNB
FEED_MAX_AGE = 45 * 60

tp.ERRORS.update({sel(s): s for s in (
    "TargetBelowMinimum(uint256,uint256)", "CapExceeded(uint256,uint256,uint256)", "StalePrice()", "InvalidPrice()",
    "CreatorNotAuthorized(address)", "NotVerified()", "InvalidConfig()")})

tp.STATE_FILE = REPO / "logs" / "testnet" / "testnet_atlas_bnb_97.json"
tp.state = json.loads(tp.STATE_FILE.read_text()) if tp.STATE_FILE.exists() else {"txs": []}
S = tp.state


def u(to: str, sig: str, *args: str) -> int:
    return first_int(call(to, sig, *args))


def usd(x: int) -> str:
    return f"${x / E18:,.2f}"


def cfg_data(salt: bytes, target: int) -> str:
    return "0x" + abi_encode([CONFIG_T], [("vLEI Atlas BNB Note", "VABN", "", salt, target, SALE_DURATION, CAP_USD)]).hex()


def done(k: str) -> bool:
    return k in S.setdefault("done", {})


def mark(k: str, v="ok") -> None:
    S["done"][k] = v
    tp.save_state()


def feed_age() -> int:
    upd = first_int(call(FEED, "latestRoundData()(uint80,int256,uint256,uint256,uint80)").split("\n")[3])
    now = int(tp.rpc("eth_getBlockByNumber", ["latest", False])["timestamp"], 16)
    return now - upd


def main() -> None:
    tp.pick_rpc()
    alice = ADDR["alice"]
    step("0. preflight")
    if call(tp.REGISTRY, "canLaunch(address)(bool)", alice) != "true":
        raise Stop("alice cannot launch (re-verify alice as OOR first)")
    age = feed_age()
    if age > FEED_MAX_AGE:
        print(f"     Atlas price is {age}s old: pushing a fresh signed report")
        subprocess.run([sys.executable, str(REPO / "scripts" / "push_atlas_price.py")], check=True, cwd=REPO)
        age = feed_age()
    px = u(FACTORY, "quoteUsd(uint256)(uint256)", str(E18))
    print(f"     Atlas BNB/USD {usd(px)} (age {age}s), minTargetUsd {usd(u(FACTORY, 'minTargetUsd()(uint256)'))}, "
          f"alice {eth(tp.balance(alice))} tBNB")
    need = 5 * 10**15 + 2 * CONTRIB + 3 * 10**15
    if tp.balance(alice) < need:
        send("deployer", alice, value=need - tp.balance(alice) + 2 * 10**15, label="deployer funds alice")

    fee = u(PORTAL, "SALT_LOCK_FEE()(uint256)")
    step("1. newLauncher with a 1 BNB target: Atlas values it below minTargetUsd")
    if not done("low_target"):
        salt = mine_salt(f"atlas-low-{alice}-{time.time()}".encode())
        rec = send("alice", PORTAL, calldata("newLauncher(address,bytes)", FACTORY, cfg_data(salt, LOW_TARGET)),
                   value=fee, label="alice newLauncher 1 BNB target (Atlas-priced)",
                   expect_revert="TargetBelowMinimum", gas=1_500_000)
        mark("low_target", rec["_entry"]["hash"])

    step("2. newLauncher with a 3.2 BNB target, cap $10 per entity")
    if not S.get("launcher"):
        salt = mine_salt(f"atlas-bnb-{alice}-{time.time()}".encode())
        token = predict_token(salt)
        launcher = to_checksum_address(call(FACTORY, "predictLauncher(address,bytes32)(address)", alice, "0x" + salt.hex()))
        S.update({"salt": "0x" + salt.hex(), "token": token})
        send("alice", PORTAL, calldata("newLauncher(address,bytes)", FACTORY, cfg_data(salt, TARGET)), value=fee,
             label="alice newLauncher 3.2 BNB target (Atlas-priced)")
        S["launcher"] = launcher
        tp.save_state()
    L = S["launcher"]
    if call(FACTORY, "isLauncher(address)(bool)", L) != "true":
        raise Stop(f"{L} is not a launcher of the factory")
    print(f"     launcher {L}, token {S['token']}, target worth {usd(u(L, 'quoteUsd(uint256)(uint256)', str(TARGET)))}")

    step("3. alice contribute 0.01 BNB: valued by Atlas against the $10 entity cap")
    if not done("contrib1"):
        rec = send("alice", L, calldata("contribute()"), value=CONTRIB, label="alice contribute 0.01 BNB")
        mark("contrib1", rec["_entry"]["hash"])
    print(f"     contribution {eth(u(L, 'contributionOf(address)(uint256)', alice))} BNB, remaining cap "
          f"{usd(u(L, 'remainingCapUsd(address)(uint256)', alice))}")

    step("4. alice contribute 0.01 BNB again: Atlas-valued total exceeds the $10 cap")
    if not done("contrib2"):
        rec = send("alice", L, calldata("contribute()"), value=CONTRIB, label="alice contribute 0.01 BNB over cap",
                   expect_revert="CapExceeded", gas=300_000)
        mark("contrib2", rec["_entry"]["hash"])

    step("summary")
    for t in S["txs"]:
        print(f"     {t['status']:<8} {t['label']:<48} {t['url']}")


if __name__ == "__main__":
    try:
        main()
    except Stop as e:
        print(f"STOP: {e}")
        sys.exit(1)
