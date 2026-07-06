#!/usr/bin/env bash
# Build Firstmate.app with py2app.
#
# py2app 0.28 aborts if the distribution has install_requires, which our
# pyproject.toml [project].dependencies populates. setup.py already carries
# everything py2app needs, so we hide pyproject.toml for the duration of the
# build and always restore it.
set -euo pipefail
cd "$(dirname "$0")"

VENV=.venv/bin/python
[ -x "$VENV" ] || { echo "no venv - run: python3.12 -m venv .venv && .venv/bin/pip install -e ."; exit 1; }

restore() { [ -f pyproject.toml.build-bak ] && mv -f pyproject.toml.build-bak pyproject.toml; }
trap restore EXIT

rm -rf build dist
[ -f pyproject.toml ] && mv pyproject.toml pyproject.toml.build-bak

MODE="${1:-}"
if [ "$MODE" = "--alias" ] || [ "$MODE" = "-A" ]; then
  echo "Building Firstmate.app (alias mode - runs from source, not distributable)…"
  "$VENV" setup.py py2app -A
else
  echo "Building Firstmate.app (standalone)…"
  "$VENV" setup.py py2app
fi

restore; trap - EXIT
echo ""
echo "✓ Built: $(pwd)/dist/Firstmate.app"
echo "  Open with:  open dist/Firstmate.app"
