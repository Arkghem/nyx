#!/usr/bin/env bash
#
# Benchmark an experiment and write a JSON report.
#
# Usage:
#   ./scripts/bench.sh                                  # active experiment
#   ./scripts/bench.sh 01_perf_probe                    # named experiment
#   ./scripts/bench.sh --frames 300 --warmup 60
#   ./scripts/bench.sh --repeat 5                       # more runs, best one wins
#   ./scripts/bench.sh --baseline                       # write reports/baselines/
#   ./scripts/bench.sh -- --width 1280 --height 720     # extra experiment args
#
# Every experiment that supports benchmarking accepts --bench-warmup,
# --bench-frames and --bench-out; see libs/profile/include/nx/profile/bench_options.h.
#
# The benchmark runs --repeat times (default 3) and scripts/bench_pick.py keeps
# the least disturbed run. Between-run variance on this machine is far larger
# than within-run variance, so a single run is not a measurement.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

experiment=""
warmup=60
frames=600
repeat=3
metric="p95"
baseline=0
out=""
extra=()

while [ "$#" -gt 0 ]; do
    case "$1" in
        --warmup)   warmup="$2"; shift 2 ;;
        --frames)   frames="$2"; shift 2 ;;
        --repeat)   repeat="$2"; shift 2 ;;
        --metric)   metric="$2"; shift 2 ;;
        --baseline) baseline=1; shift ;;
        --out)      out="$2"; shift 2 ;;
        --)         shift; extra=("$@"); break ;;
        -h|--help)
            sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        -*) echo "error: unknown option '$1'" >&2; exit 2 ;;
        *)
            if [ -n "$experiment" ]; then
                echo "error: unexpected extra argument '$1'" >&2
                exit 2
            fi
            experiment="$1"
            shift
            ;;
    esac
done

if [ -z "$experiment" ]; then
    if [ ! -f "$ROOT/.nx-active" ]; then
        echo "error: no active experiment — run ./scripts/use.sh <experiment>" >&2
        exit 1
    fi
    experiment="$(tr -d '[:space:]' < "$ROOT/.nx-active")"
fi

binary="$ROOT/.build/bin/$experiment"
if [ ! -x "$binary" ]; then
    echo "== $experiment not built yet, building =="
    "$ROOT/scripts/build.sh" "$experiment"
fi
if [ ! -x "$binary" ]; then
    echo "error: $binary is missing after the build" >&2
    exit 1
fi

stamp="$(date +%Y%m%d-%H%M%S)"
if [ -n "$out" ]; then
    report="$out"
elif [ "$baseline" -eq 1 ]; then
    report="reports/baselines/${experiment}.json"
else
    report="reports/bench/${experiment}_${stamp}.json"
fi

mkdir -p "$(dirname "$report")" "reports/bench"

echo "== benchmark $experiment (warmup=$warmup frames=$frames repeat=$repeat) =="

run_reports=()
for run in $(seq 1 "$repeat"); do
    run_report="reports/bench/${experiment}_${stamp}_run${run}.json"
    echo "-- run $run/$repeat --"
    "$binary" "${extra[@]+"${extra[@]}"}" \
        --bench-warmup "$warmup" \
        --bench-frames "$frames" \
        --bench-out "$run_report"

    # An experiment that ignores the benchmark flags would otherwise look like a
    # success while producing nothing to gate on.
    if [ ! -f "$run_report" ]; then
        echo "" >&2
        echo "error: $experiment did not write $run_report" >&2
        echo "       the experiment has to implement the benchmark contract:" >&2
        echo "       libs/profile/include/nx/profile/bench_options.h" >&2
        exit 1
    fi
    run_reports+=("$run_report")
done

echo ""
if [ "$repeat" -gt 1 ]; then
    # Between-run variance dominates within-run variance on this machine, so the
    # reported number is the least disturbed run rather than an average.
    python3 "$ROOT/scripts/bench_pick.py" \
        --metric "$metric" \
        --out "$report" \
        "${run_reports[@]}"
else
    cp "${run_reports[0]}" "$report"
fi

echo ""
echo "report: $report"
if [ "$baseline" -eq 1 ]; then
    echo "note  : baseline updated — commit it so perf_gate.py has something to compare against"
fi
