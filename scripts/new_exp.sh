#!/usr/bin/env bash
#
# Create a new experiment from core/_template.
#
# Usage: ./scripts/new_exp.sh <name> [--link]
#
#   <name>    directory name under core/, e.g. 05_svgf_denoise
#   --link    also make it the active experiment
#
# The generated experiment configures and builds immediately, so the workflow is
# always: create, build, then start changing code.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$ROOT/core/_template"

link=0
name=""

for arg in "$@"; do
    case "$arg" in
        --link) link=1 ;;
        -h|--help)
            echo "usage: ./scripts/new_exp.sh <name> [--link]"
            exit 0
            ;;
        *)
            if [ -n "$name" ]; then
                echo "error: unexpected extra argument '$arg'" >&2
                exit 2
            fi
            name="$arg"
            ;;
    esac
done

if [ -z "$name" ]; then
    echo "usage: ./scripts/new_exp.sh <name> [--link]" >&2
    exit 2
fi

if ! printf '%s' "$name" | grep -Eq '^[A-Za-z0-9_]+$'; then
    echo "error: '$name' must contain only letters, digits and underscores" >&2
    exit 2
fi

if [ -e "$ROOT/core/$name" ]; then
    echo "error: core/$name already exists" >&2
    exit 1
fi

if [ ! -f "$TEMPLATE/experiment.cmake" ]; then
    echo "error: template missing at core/_template" >&2
    exit 1
fi

cp -R "$TEMPLATE" "$ROOT/core/$name"

# The template refers to itself as _template in three places: the target name,
# the metallib it loads and its default output image.
sed -i '' "s/NAME    _template/NAME    $name/" "$ROOT/core/$name/experiment.cmake"
sed -i '' "s/_template\.metallib/$name.metallib/" "$ROOT/core/$name/src/main.mm"
sed -i '' "s|outputs/_template\.exr|outputs/$name.exr|" "$ROOT/core/$name/src/main.mm"

echo "created core/$name"
echo "  declaration: core/$name/experiment.cmake"

if [ "$link" -eq 1 ]; then
    "$ROOT/scripts/use.sh" "$name"
else
    echo "  activate   : ./scripts/use.sh $name"
fi
