#!/usr/bin/env bash
#
# Build The-Forge's framework static library (libThe-Forge.a).
#
# The-Forge ships no CMake build at all — zero CMakeLists.txt in the whole
# repository — so nyx never tries to build it through CMake. This script drives
# The-Forge's own Xcode project with xcodebuild, and cmake/NxForge.cmake only
# locates the artefact afterwards.
#
# Usage:
#   ./scripts/build_forge.sh              # Debug
#   ./scripts/build_forge.sh --release
#   ./scripts/build_forge.sh --dry-run    # print the command only
#
# Everything lands inside the repository: the file sandbox refuses writes to
# ~/Library/Developer/Xcode/DerivedData.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORGE_ROOT="${FORGE_ROOT:-$ROOT/forge}"

configuration="Debug"
dry_run=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --release) configuration="Release" ;;
        --debug)   configuration="Debug" ;;
        --dry-run) dry_run=1 ;;
        -h|--help)
            sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "error: unknown option '$1'" >&2; exit 2 ;;
    esac
    shift
done

if [ ! -d "$FORGE_ROOT" ]; then
    cat >&2 <<EOF
error: no The-Forge checkout at $FORGE_ROOT

Add the submodule first:

  git submodule add https://github.com/ConfettiFX/The-Forge.git forge
  git -C forge checkout cd5046893faba2dc7869243873bf01f02a6f0df9
EOF
    exit 1
fi

project="$FORGE_ROOT/Examples_3/Unit_Tests/macOS_Xcode/The-Forge/The-Forge.xcodeproj"
if [ ! -d "$project" ]; then
    echo "error: expected the framework project at $project" >&2
    echo "       the upstream layout may have changed; check Examples_3/Unit_Tests/macOS_Xcode/" >&2
    exit 1
fi

derived="$ROOT/.build/xcode-derived"

# GCC_TREAT_WARNINGS_AS_ERRORS=NO is set on the command line: the upstream
# project sets it to YES, which newer Xcode toolchains are very good at turning
# into build failures in code nobody is going to fix here.
command=(
    xcodebuild
    -project "$project"
    -scheme The-Forge
    -configuration "$configuration"
    -derivedDataPath "$derived"
    GCC_TREAT_WARNINGS_AS_ERRORS=NO
    build
)

echo "== building The-Forge ($configuration) =="
echo "${command[*]}"

if [ "$dry_run" -eq 1 ]; then
    exit 0
fi

"${command[@]}"

library="$(find "$FORGE_ROOT/Examples_3/Unit_Tests/macOS_Xcode/The-Forge/Bin" \
    -name 'libThe-Forge.a' -print -quit 2>/dev/null || true)"

if [ -z "$library" ]; then
    echo "" >&2
    echo "warning: the build finished but libThe-Forge.a was not found under" >&2
    echo "         $FORGE_ROOT/Examples_3/Unit_Tests/macOS_Xcode/The-Forge/Bin" >&2
    echo "         cmake/NxForge.cmake looks exactly there." >&2
    exit 1
fi

echo ""
echo "library: $library"
echo "next   : re-run ./scripts/build.sh so NxForge.cmake picks the library up"
