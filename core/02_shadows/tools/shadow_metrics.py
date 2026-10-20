#!/usr/bin/env python3
"""Shadow-specific metrics between a visibility reference and a realtime mask.

The reference is the ray-cast EXR from tools/raycast_ref.py:
    R visibility, G object mask, B max(dot(n, -light), 0), A 1
The test is the renderer's visibility EXR (one channel, or RGBA with the mask in
R).

Metrics
    mask_iou        binary intersection over union at 0.5
    mame            mean absolute visibility error
    false_shadow    reference lit (R > 0.99) but test shadowed (< 0.5), in %
                    - this is acne / over-shadowing
    false_lit       reference shadowed (R < 0.01) but test lit (> 0.5), in %
                    - this is peter-panning, bias too large, or light leaking
    edge_transition median width in pixels of the partial region
                    (0.05 < V < 0.95) per row; 0 for a hard mask and roughly the
                    filter footprint for PCF. It is a screen-space transition
                    width, not a physically calibrated penumbra; the contact
                    scene in P2 is what turns it into an actual penumbra
                    measurement.

The ROI is object (G > 0.5) and light-facing (B > 0.05). Back-facing pixels are
excluded because their visibility does not affect radiance in this scene.

Usage
    python3 core/02_shadows/tools/shadow_metrics.py \
        --reference references/_smoke/shadow_basic_mask.exr \
        --test outputs/02_shadows/shadow_basic_sm_768x768_sm2048_b0.001_seed0_vis.exr \
        --variant sm --scene shadow_basic \
        --out reports/quality/shadow_basic_sm.json
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import sys
from pathlib import Path

import numpy as np

REPO_ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO_ROOT / "scripts"))


def prepare_environment() -> None:
    os.environ.setdefault("DRJIT_CACHE_DIR", str(REPO_ROOT / ".cache" / "drjit"))
    if "DRJIT_LIBLLVM_PATH" not in os.environ:
        candidates = sorted(glob.glob("/opt/homebrew/opt/llvm*/lib/libLLVM.dylib"))
        if candidates:
            os.environ["DRJIT_LIBLLVM_PATH"] = candidates[-1]


def load_image(path: Path) -> np.ndarray:
    import mitsuba as mi

    mi.set_variant(os.environ.get("MI_DEFAULT_VARIANT", "metal_ad_rgb"))
    import nx_io

    image = np.asarray(nx_io.load_exr(path), dtype=np.float64)
    if image.ndim == 2:
        image = image[..., None]
    return image


def channel(image: np.ndarray, index: int) -> np.ndarray:
    if image.shape[2] == 1:
        return image[..., 0]
    return image[..., min(index, image.shape[2] - 1)]


def edge_transition_width(visibility: np.ndarray, roi: np.ndarray,
                          low: float = 0.05, high: float = 0.95) -> float:
    """Median width of a contiguous partial (0.05, 0.95) run.

    Rows without a partial run do not contribute: most rows do not cross a
    shadow edge, and including them as zeros would make the median useless.
    Taking contiguous runs rather than the span of all partial pixels matters
    when a row crosses two separate shadows; the span would report the distance
    between them (hundreds of pixels), not the transition width.
    """
    run_widths = []
    height = visibility.shape[0]
    for y in range(height):
        valid = roi[y]
        if not valid.any():
            continue
        xs = np.nonzero(valid)[0]
        x0, x1 = int(xs[0]), int(xs[-1])
        segment = visibility[y, x0 : x1 + 1]
        partial = (segment > low) & (segment < high)
        if not partial.any():
            continue
        indices = np.nonzero(partial)[0]
        breaks = np.nonzero(np.diff(indices) > 1)[0]
        starts = np.r_[0, breaks + 1]
        ends = np.r_[breaks, len(indices) - 1]
        for start, end in zip(starts, ends):
            run_widths.append(float(indices[end] - indices[start] + 1))
    if not run_widths:
        return 0.0
    return float(np.median(run_widths))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Shadow visibility metrics.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--reference", required=True, type=Path,
                        help="ray-cast reference EXR (R visibility, G object, B ndotl)")
    parser.add_argument("--test", required=True, type=Path,
                        help="renderer visibility EXR")
    parser.add_argument("--variant", default="")
    parser.add_argument("--tag", default="", help="join key for the Pareto table (default: variant)")
    parser.add_argument("--scene", default="")
    parser.add_argument("--out", type=Path, help="write metrics as JSON")
    parser.add_argument("--shadow-size", type=int, default=0)
    parser.add_argument("--bias", type=float, default=None)
    parser.add_argument("--notes", default="")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    prepare_environment()

    try:
        reference = load_image(args.reference)
        test = load_image(args.test)
    except Exception as exc:  # noqa: BLE001
        print(f"error: cannot read input: {exc}", file=sys.stderr)
        return 1

    if reference.shape[:2] != test.shape[:2]:
        print(f"error: resolution mismatch: {reference.shape[:2]} vs {test.shape[:2]}",
              file=sys.stderr)
        return 2
    if reference.shape[2] < 2:
        print("error: the reference must have at least 2 channels (visibility, object); "
              "use tools/raycast_ref.py", file=sys.stderr)
        return 2

    ref_visibility = channel(reference, 0)
    object_mask = reference[..., 1] > 0.5
    ndotl = reference[..., 2] if reference.shape[2] > 2 else np.ones_like(ref_visibility)
    roi = object_mask & (ndotl > 0.05)

    if not roi.any():
        print("error: the ROI is empty", file=sys.stderr)
        return 2

    test_visibility = channel(test, 0)
    if test_visibility.shape != ref_visibility.shape:
        print("error: test visibility shape does not match the reference", file=sys.stderr)
        return 2

    ref_binary = ref_visibility > 0.5
    test_binary = test_visibility > 0.5
    intersection = np.logical_and(ref_binary[roi], test_binary[roi]).sum()
    union = np.logical_or(ref_binary[roi], test_binary[roi]).sum()
    mask_iou = float(intersection / union) if union > 0 else float("nan")

    difference = np.abs(ref_visibility[roi] - test_visibility[roi])
    mame = float(difference.mean())
    max_abs = float(difference.max())

    false_shadow = float(
        ((ref_visibility[roi] > 0.99) & (test_visibility[roi] < 0.5)).mean()
    )
    false_lit = float(
        ((ref_visibility[roi] < 0.01) & (test_visibility[roi] > 0.5)).mean()
    )
    ref_soft = float(((ref_visibility[roi] > 0.05) & (ref_visibility[roi] < 0.95)).mean())
    test_soft = float(((test_visibility[roi] > 0.05) & (test_visibility[roi] < 0.95)).mean())

    ref_edge = edge_transition_width(ref_visibility, roi)
    test_edge = edge_transition_width(test_visibility, roi)

    metrics = {
        "mask_iou": mask_iou,
        "mame": mame,
        "max_abs": max_abs,
        "false_shadow_pct": false_shadow * 100.0,
        "false_lit_pct": false_lit * 100.0,
        "reference_soft_fraction": ref_soft,
        "test_soft_fraction": test_soft,
        "reference_edge_px": ref_edge,
        "test_edge_px": test_edge,
        "roi_pixels": int(roi.sum()),
        "coverage": float(object_mask.mean()),
        "reference_shadow_fraction": float((ref_visibility[roi] < 0.5).mean()),
        "test_shadow_fraction": float((test_visibility[roi] < 0.5).mean()),
    }

    print(f"reference : {args.reference}")
    print(f"test      : {args.test}")
    print(f"roi       : {int(roi.sum())} pixels (object and light-facing)")
    print("")
    print(f"mask IoU  : {mask_iou:.6f}")
    print(f"MAME      : {mame:.6f}")
    print(f"max abs   : {max_abs:.6f}")
    print(f"false shadow (acne)        : {false_shadow * 100.0:.4f}%")
    print(f"false lit (peter-pan/leak) : {false_lit * 100.0:.4f}%")
    print(f"soft reference / test      : {ref_soft * 100.0:.3f}% / {test_soft * 100.0:.3f}%")
    print(f"edge transition px         : ref={ref_edge:.2f} test={test_edge:.2f}")

    if args.out is not None:
        payload = {
            "experiment": "02_shadows",
            "variant": args.variant,
            "tag": args.tag or args.variant,
            "scene": args.scene,
            "reference": str(args.reference),
            "test": str(args.test),
            "resolution": [int(reference.shape[1]), int(reference.shape[0])],
            "shadow_size": args.shadow_size,
            "bias": args.bias,
            "notes": args.notes,
            "metrics": metrics,
            "command": " ".join(sys.argv),
        }
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
        print(f"metrics   : {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
