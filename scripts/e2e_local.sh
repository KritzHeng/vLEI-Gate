#!/usr/bin/env bash
# End-to-end test on an anvil FORK of BNB Testnet (chainId 97) with the live Flap Portal.
# See scripts/e2e_local.py for the flow.
# Requires Foundry (anvil, forge, cast), jq, the backend venv (backend/.venv) and network access to a
# BNB Testnet RPC: $BSC_TESTNET_RPC_URL (or $BSC_TESTNET_RPC), default https://bsc-testnet-rpc.publicnode.com.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="$ROOT/backend/.venv/bin/python"
if [ ! -x "$PY" ]; then
  echo "backend venv missing: python3.12 -m venv backend/.venv && backend/.venv/bin/pip install -r backend/requirements.txt" >&2
  exit 1
fi
( cd "$ROOT/contracts" && FOUNDRY_DISABLE_NIGHTLY_WARNING=1 forge build --quiet )
exec "$PY" "$ROOT/scripts/e2e_local.py" "$@"
