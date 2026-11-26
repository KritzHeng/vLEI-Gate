#!/usr/bin/env bash
# Enable a VLEILauncherFactory on the Flap Portal of an ANVIL FORK of BNB Testnet / BNB Chain.
#
# Opening a factory is a Portal admin action: setLauncherFactoryMultiplier needs DEFAULT_ADMIN, MANAGE or AUDITOR
# role. The admin is the owner of the Portal's ProxyAdmin (0x3bfC05a8b9e48FdFd6A443657caC5D983B664a05 on testnet at
# the time of writing). The Flap Guardian has NO Portal role and cannot do this.
#
# Usage:  script/enable_factory_fork.sh [factory] [rpc]
#   factory  default: .factory from deployments/97.json (or $DEPLOYMENTS_FILE)
#   rpc      default: $RPC_URL or http://127.0.0.1:8545
# Requires: anvil running with --fork-url, cast, jq (only when factory is read from the JSON).
set -euo pipefail
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1

PORTAL=${FLAP_PORTAL:-0x000042108465206185A077Edc3F3fd2b49060000}
PROXY_ADMIN=${FLAP_PORTAL_PROXY_ADMIN:-0x0000Ed588dfc01749C20bA69b5f8c77d706E0000}
RPC=${2:-${RPC_URL:-http://127.0.0.1:8545}}
DIR="$(cd "$(dirname "$0")/.." && pwd)"
FACTORY=${1:-}
if [ -z "$FACTORY" ]; then
  FILE=${DEPLOYMENTS_FILE:-$DIR/deployments/97.json}
  FACTORY=$(jq -r .factory "$FILE")
fi

ADMIN=$(cast call "$PROXY_ADMIN" 'owner()(address)' --rpc-url "$RPC")
echo "Portal admin: $ADMIN"
cast rpc anvil_impersonateAccount "$ADMIN" --rpc-url "$RPC" >/dev/null
cast rpc anvil_setBalance "$ADMIN" 0x56BC75E2D63100000 --rpc-url "$RPC" >/dev/null
cast send "$PORTAL" 'setLauncherFactoryMultiplier(address,uint16,bool)' "$FACTORY" 10000 true \
  --from "$ADMIN" --unlocked --rpc-url "$RPC" >/dev/null
cast rpc anvil_stopImpersonatingAccount "$ADMIN" --rpc-url "$RPC" >/dev/null

echo "launcherFactoryMultiplier($FACTORY) = $(cast call "$PORTAL" 'launcherFactoryMultiplier(address)(bool,uint16)' "$FACTORY" --rpc-url "$RPC" | tr '\n' ' ')"
