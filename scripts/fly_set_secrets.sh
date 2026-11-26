#!/usr/bin/env bash
# Copies the backend's secrets from the repo-root .env to the Fly app, without printing any value.
# Usage: scripts/fly_set_secrets.sh [app-name]     (default: vlei-gate-api)
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:-vlei-gate-api}"
NAMES=(VERIFIER_PRIVATE_KEY CMC_API_KEY COURNOT_API_KEY)
python3 - "${NAMES[@]}" <<'PY' | fly secrets import --app "$APP" --stage
import sys
vals = {}
for line in open(".env"):
    line = line.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    k, v = line.split("=", 1)
    vals[k.strip()] = v.strip().strip('"').strip("'")
for name in sys.argv[1:]:
    if vals.get(name):
        print(f"{name}={vals[name]}")
        print(f"set {name}", file=sys.stderr)
    else:
        print(f"skip {name} (empty in .env)", file=sys.stderr)
PY
echo "secrets staged for $APP (applied on the next deploy)"
