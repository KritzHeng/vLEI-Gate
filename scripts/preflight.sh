#!/usr/bin/env bash
# Pre-demo checklist (see scripts/preflight.py). Usage: scripts/preflight.sh [--no-push]
cd "$(dirname "$0")/.." && exec "${PYTHON:-backend/.venv/bin/python}" scripts/preflight.py "$@"
