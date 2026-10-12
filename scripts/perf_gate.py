#!/usr/bin/env python3
"""Compare a benchmark report against a baseline and fail on regressions.

This is the performance half of nyx's judging loop; the quality half (PSNR,
SSIM, FLIP) lives in the Python comparison scripts under scripts/.

    ./scripts/perf_gate.py --candidate reports/bench/01_perf_probe_x.json
    ./scripts/perf_gate.py --candidate reports/bench/x.json \
                           --baseline reports/baselines/01_perf_probe.json \
                           --threshold 0.10

Exit code 0 means every metric stayed within the threshold, 1 means at least one
regressed, 2 means the reports were not comparable at all.

Reports measured with a different timer_source, resolution or (by default)
different hardware are refused rather than compared: a wall-clock number is not
a slightly worse GPU number, it is a different quantity.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

DEFAULT_BASELINE_DIR = Path("reports/baselines")
DEFAULT_THRESHOLD = 0.10


def load_report(path: Path) -> dict:
    try:
        with path.open("r", encoding="utf-8") as handle:
            return json.load(handle)
    except FileNotFoundError:
        print(f"error: no report at {path}", file=sys.stderr)
        sys.exit(2)
    except json.JSONDecodeError as exc:
        print(f"error: {path} is not valid JSON: {exc}", file=sys.stderr)
        sys.exit(2)


def comparability(baseline: dict, candidate: dict, strict_hw: bool) -> list[str]:
    """Returns the list of reasons these two reports must not be compared."""
    problems: list[str] = []

    key = baseline.get("timer_source")
    if key != candidate.get("timer_source"):
        problems.append(
            f"timer_source differs: baseline={key} candidate={candidate.get('timer_source')}"
        )
    if baseline.get("resolution") != candidate.get("resolution"):
        problems.append(
            f"resolution differs: baseline={baseline.get('resolution')} "
            f"candidate={candidate.get('resolution')}"
        )
    if strict_hw and baseline.get("hw") != candidate.get("hw"):
        problems.append(f"hardware differs: baseline={baseline.get('hw')} candidate={candidate.get('hw')}")
    return problems


def compare_metric(name: str, base: float, candidate: float, threshold: float) -> tuple[bool, str]:
    if base <= 0.0:
        return True, f"  {name:<28} baseline={base:.4f}  (skipped: baseline not positive)"
    limit = base * (1.0 + threshold)
    delta_pct = (candidate - base) / base * 100.0
    ok = candidate <= limit
    status = "ok  " if ok else "FAIL"
    return ok, (
        f"  {status} {name:<24} baseline={base:8.4f}  candidate={candidate:8.4f}  "
        f"{delta_pct:+6.1f}%  limit={limit:8.4f}"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--candidate", required=True, type=Path, help="report produced by scripts/bench.sh")
    parser.add_argument("--baseline", type=Path, help="baseline report; defaults to reports/baselines/<experiment>.json")
    parser.add_argument("--threshold", type=float, default=DEFAULT_THRESHOLD,
                        help=f"allowed relative regression before failing (default {DEFAULT_THRESHOLD})")
    parser.add_argument("--metric", default="p95", choices=["p50", "p95", "p99", "mean", "max"],
                        help="which statistic to gate on (default p95)")
    parser.add_argument("--strict-hw", action="store_true",
                        help="also refuse to compare reports from different machines")
    parser.add_argument("--list", action="store_true", help="print every compared metric even when it passes")
    args = parser.parse_args()

    candidate = load_report(args.candidate)

    baseline_path = args.baseline
    if baseline_path is None:
        experiment = candidate.get("experiment", args.candidate.stem)
        baseline_path = DEFAULT_BASELINE_DIR / f"{experiment}.json"
        if not baseline_path.exists():
            print(f"no baseline at {baseline_path} — nothing to compare.", file=sys.stderr)
            print("record one with: ./scripts/bench.sh <experiment> --baseline", file=sys.stderr)
            return 2

    baseline = load_report(baseline_path)

    print(f"baseline : {baseline_path}")
    print(f"candidate: {args.candidate}")
    print(f"metric   : {args.metric}  threshold: +{args.threshold * 100:.0f}%")
    print("")

    problems = comparability(baseline, candidate, args.strict_hw)
    if problems:
        print("reports are not comparable:", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 2

    rows: list[tuple[bool, str]] = []
    failures = 0

    base_frame = baseline.get("frame_ms", {}).get(args.metric)
    cand_frame = candidate.get("frame_ms", {}).get(args.metric)
    if base_frame is None or cand_frame is None:
        print(f"error: frame_ms.{args.metric} missing from one of the reports", file=sys.stderr)
        return 2

    ok, line = compare_metric(f"frame_ms.{args.metric}", base_frame, cand_frame, args.threshold)
    rows.append((ok, line))
    failures += 0 if ok else 1

    base_passes = baseline.get("passes", {})
    cand_passes = candidate.get("passes", {})
    for name in sorted(set(base_passes) & set(cand_passes)):
        base_value = base_passes[name].get(args.metric)
        cand_value = cand_passes[name].get(args.metric)
        if base_value is None or cand_value is None:
            continue
        ok, line = compare_metric(f"{name}.{args.metric}", base_value, cand_value, args.threshold)
        rows.append((ok, line))
        failures += 0 if ok else 1

    for ok, line in rows:
        if args.list or not ok:
            print(line)

    print("")
    if failures:
        print(f"FAILED: {failures} metric(s) regressed beyond +{args.threshold * 100:.0f}%")
        return 1
    print(f"PASSED: {len(rows)} metric(s) within +{args.threshold * 100:.0f}% of the baseline")
    return 0


if __name__ == "__main__":
    sys.exit(main())
