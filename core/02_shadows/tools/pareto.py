#!/usr/bin/env python3
"""Join quality and cost reports into a Pareto table.

A shadow technique is not "better" in isolation: the interesting question is
what quality it buys for a given p95 GPU cost, at the same scene and resolution.
This tool joins:

    reports/bench/02_shadows_<tag>_*.json      (nx::profile PerfReport)
    reports/quality/shadow_<scene>_<tag>.json  (tools/shadow_metrics.py)

on (tag, scene), checks that both were measured at the same resolution, and
prints a table plus the non-dominated set. A pipeline is dominated when another
one has both higher quality and lower cost.

Usage
    python3 core/02_shadows/tools/pareto.py \
        --scene shadow_basic --metric mask_iou \
        --out reports/quality/02_shadows_pareto.md
"""

from __future__ import annotations

import argparse
import glob
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]


def load_json(path: Path) -> dict | None:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"warning: cannot read {path}: {exc}", file=sys.stderr)
        return None


def scene_stem(value: str | None) -> str:
    return Path(value).stem if value else ""


def quality_value(metrics: dict, metric: str) -> float | None:
    if metric == "mask_iou":
        return metrics.get("mask_iou")
    if metric == "mame":
        value = metrics.get("mame")
        return None if value is None else 1.0 - float(value)
    if metric == "false_shadow":
        value = metrics.get("false_shadow_pct")
        return None if value is None else 1.0 - float(value) / 100.0
    if metric == "false_lit":
        value = metrics.get("false_lit_pct")
        return None if value is None else 1.0 - float(value) / 100.0
    raise SystemExit(f"unknown metric '{metric}'")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--bench-glob", default=str(REPO_ROOT / "reports/bench/02_shadows_*.json"))
    parser.add_argument("--quality-glob", default=str(REPO_ROOT / "reports/quality/shadow_*.json"))
    parser.add_argument("--scene", default="", help="only this scene stem (default: all)")
    parser.add_argument("--resolution", default="",
                        help="only this WxH, e.g. 1920x1080 (default: all)")
    parser.add_argument("--shadow-size", type=int, default=0,
                        help="only this shadow-map resolution (default: all)")
    parser.add_argument("--timing", default="frame", choices=["frame", "passes", "any"],
                        help="cost timing mode to use (per-pass reports are an upper bound)")
    parser.add_argument("--metric", default="mask_iou",
                        choices=["mask_iou", "mame", "false_shadow", "false_lit"])
    parser.add_argument("--out", type=Path,
                        default=REPO_ROOT / "reports/quality/02_shadows_pareto.md")
    parser.add_argument("--png", type=Path, help="optional scatter plot")
    args = parser.parse_args()

    resolution_filter = None
    if args.resolution:
        try:
            width, height = (int(x) for x in args.resolution.lower().split("x"))
            resolution_filter = (width, height)
        except ValueError:
            raise SystemExit("--resolution must look like 1920x1080")

    # Cost reports: skip the per-run intermediates, keep the picked report.
    bench: dict[tuple[str, str, tuple[int, int], int], dict] = {}
    for name in sorted(glob.glob(args.bench_glob)):
        path = Path(name)
        if "_run" in path.stem:
            continue
        data = load_json(path)
        if data is None:
            continue
        metadata = data.get("metadata", {})
        timing_mode = metadata.get("timing", "frame")
        if args.timing != "any" and timing_mode != args.timing:
            continue
        tag = metadata.get("tag") or metadata.get("variant") or path.stem
        scene = scene_stem(metadata.get("scene"))
        if args.scene and scene != args.scene:
            continue
        resolution = tuple(int(x) for x in data.get("resolution", []))
        if resolution_filter is not None and resolution != resolution_filter:
            continue
        shadow_size = int(metadata.get("shadow_size", 0) or 0)
        if args.shadow_size and shadow_size != args.shadow_size:
            continue
        bench[(tag, scene, resolution, shadow_size)] = {
            "path": path,
            "cost_ms": data.get("frame_ms", {}).get("p95"),
            "cpu_ms": data.get("cpu_frame_ms", {}).get("p95"),
            "resolution": resolution,
            "counters": data.get("counters", {}),
            "pipeline": metadata.get("pipeline", ""),
            "shadow_size": shadow_size,
        }

    # Quality reports: only shadow metric reports have mask_iou.
    quality: dict[tuple[str, str, tuple[int, int], int], dict] = {}
    for name in sorted(glob.glob(args.quality_glob)):
        path = Path(name)
        data = load_json(path)
        if data is None:
            continue
        metrics = data.get("metrics", {})
        if "mask_iou" not in metrics:
            continue
        tag = data.get("tag") or data.get("variant") or path.stem
        scene = scene_stem(data.get("scene"))
        if args.scene and scene != args.scene:
            continue
        resolution = tuple(int(x) for x in data.get("resolution", []))
        if resolution_filter is not None and resolution != resolution_filter:
            continue
        shadow_size = int(data.get("shadow_size", 0) or 0)
        if args.shadow_size and shadow_size != args.shadow_size:
            continue
        quality[(tag, scene, resolution, shadow_size)] = {
            "path": path,
            "value": quality_value(metrics, args.metric),
            "resolution": resolution,
            "metrics": metrics,
        }

    rows = []
    missing_quality = []
    missing_cost = []
    mismatched_resolution = []
    for key, cost in sorted(bench.items()):
        q = quality.get(key)
        if q is None:
            missing_quality.append(key)
            continue
        if cost["cost_ms"] is None or q["value"] is None:
            continue
        rows.append({
            "tag": key[0],
            "scene": key[1],
            "quality": float(q["value"]),
            "cost_ms": float(cost["cost_ms"]),
            "cpu_ms": cost["cpu_ms"],
            "shadow_mb": cost["counters"].get("shadow_map_bytes", 0.0) / (1024.0 * 1024.0),
            "taps": cost["counters"].get("taps", 0.0),
            "shadow_size": key[3],
            "resolution": cost["resolution"],
            "metrics": q["metrics"],
        })
    for key in quality:
        if key not in bench:
            missing_cost.append(key)

    if not rows:
        print("no joined (bench, quality) pairs found", file=sys.stderr)
        for key in missing_quality:
            print(f"  missing quality for {key}", file=sys.stderr)
        for key in missing_cost:
            print(f"  missing cost for {key}", file=sys.stderr)
        return 1

    # Non-dominated front: sort by cost, keep a row only if its quality beats
    # every cheaper row.
    rows.sort(key=lambda row: row["cost_ms"])
    best_quality = -1.0
    for row in rows:
        if row["quality"] > best_quality + 1e-12:
            row["pareto"] = True
            best_quality = row["quality"]
        else:
            row["pareto"] = False

    header = (
        f"| tag | scene | resolution | shadow | {args.metric} | p95 ms | CPU p95 ms | shadow MB | taps | Pareto |\n"
        "|---|---|---|---|---|---|---|---|---|---|\n"
    )
    lines = []
    for row in sorted(rows, key=lambda r: r["cost_ms"]):
        cpu = f"{row['cpu_ms']:.4f}" if row["cpu_ms"] is not None else "-"
        lines.append(
            f"| {row['tag']} | {row['scene']} | {row['resolution'][0]}x{row['resolution'][1]} | "
            f"{row['shadow_size']} | {row['quality']:.6f} | {row['cost_ms']:.4f} | {cpu} | "
            f"{row['shadow_mb']:.1f} | {row['taps']:.0f} | "
            f"{'yes' if row['pareto'] else 'no'} |"
        )

    text = (
        "# 02_shadows — quality / cost Pareto\n\n"
        f"Quality metric: `{args.metric}` (higher is better).\n"
        f"Cost: p95 GPU frame time from nx::profile; the camera resolution is in the table.\n\n"
        + header
        + "\n".join(lines)
        + "\n"
    )

    print(text)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(text, encoding="utf-8")
    print(f"table: {args.out}")

    for key in missing_quality:
        print(f"note: no quality report for {key} (skipped)", file=sys.stderr)
    for key in missing_cost:
        print(f"note: no cost report for {key} (skipped)", file=sys.stderr)
    for key, cost_res, quality_res in mismatched_resolution:
        print(f"note: {key} resolution mismatch cost={cost_res} quality={quality_res} "
              "(skipped; same resolution is required)", file=sys.stderr)

    if args.png is not None:
        try:
            from PIL import Image, ImageDraw
        except ImportError:
            print("warning: PIL is unavailable; skipping the PNG", file=sys.stderr)
            return 0
        width, height = 900, 600
        image = Image.new("RGB", (width, height), (18, 18, 22))
        draw = ImageDraw.Draw(image)
        max_cost = max(row["cost_ms"] for row in rows) * 1.1
        min_q = min(row["quality"] for row in rows)
        max_q = max(row["quality"] for row in rows)
        span_q = max(max_q - min_q, 1e-9)
        for row in rows:
            x = 60 + (row["cost_ms"] / max_cost) * (width - 120)
            y = height - 60 - ((row["quality"] - min_q) / span_q) * (height - 120)
            color = (80, 220, 120) if row["pareto"] else (150, 150, 160)
            draw.ellipse([x - 5, y - 5, x + 5, y + 5], fill=color)
            draw.text((x + 8, y - 6), f"{row['tag']}@{row['shadow_size']}",
                      fill=(230, 230, 230))
        draw.text((60, 20), f"quality ({args.metric}) vs p95 ms", fill=(230, 230, 230))
        args.png.parent.mkdir(parents=True, exist_ok=True)
        image.save(args.png)
        print(f"plot : {args.png}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
