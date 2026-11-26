#!/usr/bin/env bash
# Validate and package the three vLEI-Gate components with the Flap template's own tooling.
#
#   vlei-gate-launcher        launcher UI, v2 BNB factory (Atlas price) 0x394928211B03Eb74a6f7061a56973F77A7fC48a4
#   vlei-gate-vault-launcher  launcher UI, v2 USDT factory     0xEA3d889e5EA5f684268cDEcc45CE77322F0D9CeD
#   vlei-gate-vault           Vault UI,   v2 USDT vault factory 0x3C90db983d2eE6D3aa8fD88d6CF5Ae8535d49c03
#
# Launcher UIs are checked in ./template (branch test/pool-launch-developer-preview, which has
# launcher:check-source) and zipped as the three source files.
# The Vault UI is checked in ./template-main, a git worktree of the official origin/main: vault:check,
# vault:e2e and vault:package refuse to run unless HEAD == origin/main (template freshness gate).
#
# Usage: ./check.sh            (all three)
#        ./check.sh launchers  (launcher UIs only)
#        ./check.sh vault      (Vault UI only)
# Needs `yarn install` once inside ./template; vault:e2e needs `yarn playwright install chromium` once.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="$ROOT/template"
MAIN="$ROOT/template-main"
DIST="$ROOT/dist"
ONLY="${1:-all}"
mkdir -p "$DIST"

check_launcher() {
  local name="$1"
  local src="$ROOT/$name"
  local mirror="$TEMPLATE/examples/launcher-runtime/$name"
  local zip="$DIST/$name.zip"
  echo "=================== $name"
  mkdir -p "$mirror"
  cp "$src/Component.tsx" "$src/manifest.json" "$src/i18n.json" "$mirror/"
  (
    cd "$TEMPLATE"
    echo "== launcher:check-source"; yarn -s launcher:check-source "examples/launcher-runtime/$name"
    echo "== eslint";                npx eslint --max-warnings 0 "examples/launcher-runtime/$name/Component.tsx"
  )
  echo "== zip"
  rm -f "$zip"
  (cd "$src" && zip -X -j "$zip" Component.tsx manifest.json i18n.json >/dev/null)
  unzip -l "$zip"
}

ensure_main_worktree() {
  if [ ! -e "$MAIN/.git" ]; then
    echo "== creating $MAIN (worktree of origin/main)"
    git -C "$TEMPLATE" fetch origin main:refs/remotes/origin/main
    git -C "$TEMPLATE" worktree add --detach "$MAIN" origin/main
  fi
  [ -e "$MAIN/node_modules" ] || ln -s ../template/node_modules "$MAIN/node_modules"
}

check_vault() {
  local name="vlei-gate-vault"
  local dest="$MAIN/src/vaults/$name"
  echo "=================== $name"
  ensure_main_worktree
  mkdir -p "$dest"
  cp "$ROOT/$name/Component.tsx" "$ROOT/$name/manifest.json" "$ROOT/$name/VaultABI.ts" "$ROOT/$name/i18n.json" "$dest/"
  (
    cd "$MAIN"
    grep -q "\"$name\"" src/vaults/index.ts || yarn -s vault:register "$name" >/dev/null
    echo "== vault:check";          yarn -s vault:check "$name" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const r=JSON.parse(s);console.log(JSON.stringify({ok:r.ok,summary:r.summary}));if(!r.ok)process.exit(1)})'
    echo "== eslint";               npx eslint --max-warnings 0 "src/vaults/$name/Component.tsx" "src/vaults/$name/VaultABI.ts"
    echo "== vault:e2e";            yarn -s vault:e2e "$name" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const r=JSON.parse(s);console.log(JSON.stringify({ok:r.ok,summary:r.summary}));if(!r.ok)process.exit(1)})'
    echo "== vault:package";        yarn -s vault:package "$name" >/dev/null
    echo "== vault:verify-package"; yarn -s vault:verify-package "dist/$name.zip" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const r=JSON.parse(s);console.log(JSON.stringify({ok:r.ok}));if(!r.ok)process.exit(1)})'
  )
  cp "$MAIN/dist/$name.zip" "$DIST/$name.zip"
  unzip -l "$DIST/$name.zip"
}

if [ "$ONLY" = all ] || [ "$ONLY" = launchers ]; then
  check_launcher vlei-gate-launcher
  check_launcher vlei-gate-vault-launcher
  echo "== typecheck (template, covers both launcher mirrors)"; (cd "$TEMPLATE" && yarn -s typecheck)
fi
if [ "$ONLY" = all ] || [ "$ONLY" = vault ]; then
  check_vault
  echo "== typecheck (template-main, covers the Vault UI)"; (cd "$MAIN" && yarn -s typecheck)
fi
echo "== done: $(ls "$DIST")"
