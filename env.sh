#!/usr/bin/env bash
# nyx environment.
#
# Source this file before running anything in the repository:
#
#   source env.sh
#
# It exists because three of the settings below are not optional on this
# machine: the file sandbox, the LLVM-backed Mitsuba variants, and a stale
# cmake that shadows the Homebrew one.

# Resolve the repository root from this script's location, so `source env.sh`
# works from any working directory.
NYX_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export NYX_ROOT

# The-Forge checkout (git submodule, added during init).
export FORGE_ROOT="${FORGE_ROOT:-$NYX_ROOT/forge}"

# Homebrew's cmake is newer than the python-installed one that shadows it in the
# default PATH. Pinning it explicitly is better than prepending /opt/homebrew/bin
# to PATH: reordering PATH would also change which python3, git and make
# resolve, and the python3 from Homebrew does not have Mitsuba.
if [ -x /opt/homebrew/bin/cmake ]; then
    export NX_CMAKE="${NX_CMAKE:-/opt/homebrew/bin/cmake}"
fi

# drjit writes a JIT cache on first import. Its default location (~/.drjit) is
# outside the repository, so the sandbox denies the write and every run pays
# full JIT compilation. Keep it inside the tree.
export DRJIT_CACHE_DIR="$NYX_ROOT/.cache/drjit"
mkdir -p "$DRJIT_CACHE_DIR"

# The llvm_* Mitsuba variants need libLLVM.dylib at import time; without this
# they fail with "the LLVM backend is inactive". The metal_* variants do not
# need it, but setting it unconditionally also silences the noisy
# "jitc_llvm_init(): LLVM API initialization failed" banner.
NYX_LLVM_DYLIB="$(ls /opt/homebrew/opt/llvm*/lib/libLLVM.dylib 2>/dev/null | head -n 1)"
if [ -n "$NYX_LLVM_DYLIB" ]; then
    export DRJIT_LIBLLVM_PATH="$NYX_LLVM_DYLIB"
fi
unset NYX_LLVM_DYLIB

# Default Mitsuba variant. metal_ad_rgb uses the Apple Silicon ray tracing
# hardware and was measured to be bit-identical to llvm_ad_rgb.
export MI_DEFAULT_VARIANT="${MI_DEFAULT_VARIANT:-metal_ad_rgb}"

# Project virtual environment, created by scripts/check_env.py or manually.
# This does belong at the front of PATH: it is the interpreter the scripts
# should use, and it is opt-in by existing.
if [ -d "$NYX_ROOT/.venv/bin" ]; then
    export PATH="$NYX_ROOT/.venv/bin:$PATH"
    export VIRTUAL_ENV="$NYX_ROOT/.venv"
fi

# Keep FetchContent's downloads inside the repository too.
export NYX_THIRD_PARTY_DIR="$NYX_ROOT/third_party"
