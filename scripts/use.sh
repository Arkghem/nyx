#!/usr/bin/env bash
#
# Select the active experiment.
#
# Writes the experiment name to .nx-active and repoints the `entry` symlink at
# core/<name>. CMake only reads .nx-active; the symlink exists so editors and
# tools that expect a stable path (entry/src/main.mm) keep working.
#
# Usage: ./scripts/use.sh <experiment>

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
    echo "usage: ./scripts/use.sh <experiment>" >&2
    echo "" >&2
    echo "available experiments:" >&2
    for dir in "$ROOT"/core/*/; do
        name="$(basename "$dir")"
        case "$name" in
            _*) continue ;;
        esac
        if [ -f "$dir/experiment.cmake" ]; then
            echo "  $name" >&2
        fi
    done
}

if [ "$#" -ne 1 ]; then
    usage
    exit 2
fi

experiment="$1"
target="$ROOT/core/$experiment"

if [ ! -f "$target/experiment.cmake" ]; then
    echo "error: no experiment at core/$experiment" >&2
    usage
    exit 1
fi

echo "$experiment" > "$ROOT/.nx-active"
ln -sfn "core/$experiment" "$ROOT/entry"

echo "active experiment: $experiment"
echo "  entry  -> core/$experiment"
echo "  build  : ./scripts/build.sh"
echo "  run    : ./scripts/run.sh"
