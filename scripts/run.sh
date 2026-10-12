#!/usr/bin/env bash
#
# Run the active experiment.
#
# Usage:
#   ./scripts/run.sh [arguments...]
#
# Looks up the experiment recorded in .nx-active, runs its executable from
# .build/bin, and forwards every argument. Builds first when the binary is
# missing.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [ ! -f "$ROOT/.nx-active" ]; then
    echo "error: no active experiment — run ./scripts/use.sh <experiment>" >&2
    exit 1
fi

experiment="$(tr -d '[:space:]' < "$ROOT/.nx-active")"
binary="$ROOT/.build/bin/$experiment"

if [ ! -x "$binary" ]; then
    echo "== $experiment not built yet, building =="
    "$ROOT/scripts/build.sh" "$experiment"
fi

if [ ! -x "$binary" ]; then
    echo "error: $binary is still missing after the build" >&2
    exit 1
fi

exec "$binary" "$@"
