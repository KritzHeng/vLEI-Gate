#!/usr/bin/env bash
# Keeps the Atlas BNB/USD price on AtlasSignedFeed fresh (the v2 BNB factory rejects prices older than 1 h).
# Pushes a signed Atlas report every ATLAS_KEEPER_INTERVAL seconds (default 1800) via push_atlas_price.py,
# which checks consensus, freshness, the Atlas signature and the CoinMarketCap cross-check before sending.
# Usage: scripts/atlas_keeper.sh            (Ctrl-C to stop; output never includes keys)
set -u
cd "$(dirname "$0")/.."
PY="${PYTHON:-backend/.venv/bin/python}"
INTERVAL="${ATLAS_KEEPER_INTERVAL:-1800}"
while true; do
  echo "=== $(date '+%F %T')"
  "$PY" scripts/push_atlas_price.py 2>&1 | grep -viE 'api.?key|private' | tail -5
  sleep "$INTERVAL"
done
