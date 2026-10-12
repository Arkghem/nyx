#!/usr/bin/env bash
#
# Configure and build.
#
# Usage:
#   ./scripts/build.sh                     # build the active experiment (Debug)
#   ./scripts/build.sh --release           # same, Release
#   ./scripts/build.sh --all               # build every experiment (Debug)
#   ./scripts/build.sh --configure-only    # configure without building
#   ./scripts/build.sh <target>            # build one target
#
# Derived data and the build tree live inside the repository because the file
# sandbox refuses writes anywhere else.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

build_type="Debug"
preset="macos-debug"
configure_only=0
targets=()

while [ "$#" -gt 0 ]; do
    case "$1" in
        --release)        build_type="Release"; preset="macos-release" ;;
        --debug)          build_type="Debug";   preset="macos-debug" ;;
        --all)            preset="macos-all" ;;
        --configure-only) configure_only=1 ;;
        -h|--help)
            sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        -*) echo "error: unknown option '$1'" >&2; exit 2 ;;
        *)  targets+=("$1") ;;
    esac
    shift
done

if [ "$preset" = "macos-all" ]; then
    build_type="Debug"
fi

jobs="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
# env.sh pins the Homebrew cmake here; fall back to whatever is on PATH.
cmake_bin="${NX_CMAKE:-cmake}"

echo "== configure ($preset, $build_type) =="
"$cmake_bin" --preset "$preset"

if [ "$configure_only" -eq 1 ]; then
    exit 0
fi

echo "== build =="
if [ "${#targets[@]}" -gt 0 ]; then
    "$cmake_bin" --build --preset "$preset" --target "${targets[@]}" -j "$jobs"
else
    "$cmake_bin" --build --preset "$preset" -j "$jobs"
fi
