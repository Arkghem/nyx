#!/usr/bin/env python3
"""Compare two linear EXR images and write a diff.

Everything is computed before tone mapping. Tone mapping is only used for the
optional PNG that a human looks at; the numbers in the JSON are linear-light
numbers, which is the only way an energy error stays visible.

Metrics
    PSNR        peak = 1.0, the same convention as nx::metrics
    MAE         mean absolute error
    max         maximum absolute error
    SSIM        11x11 Gaussian window, luminance; L = max(1, reference max)
    mask IoU    if `--mask` is used or the images have a silhouette

ROI selection
    --mask none|geometry|interior   derive a mask from the reference image
    --roi PATH [--roi-ndotl]        use R > 0.5 from an EXR (e.g. the ray-cast
                                    visibility reference); --roi-ndotl also
                                    requires G > 0.5 and B > 0.05, which restricts
                                    a lit-vs-reference comparison to lit-facing,
                                    unshadowed pixels

Usage
    python3 scripts/compare.py --reference references/albedo.exr \
        --test outputs/albedo.exr --mask interior --erode 2 \
        --out-diff reports/quality/albedo_diff.exr \
        --out-png reports/quality/albedo_diff.png

    python3 scripts/compare.py --reference references/direct.exr \
        --test outputs/lit.exr --roi references/_smoke/shadow_basic_mask.exr --roi-ndotl
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import sys
from pathlib import Path

import numpy as np

REPO_ROOT = Path(__file__).resolve().parent.parent


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


def to_rgb(image: np.ndarray) -> np.ndarray:
    if image.shape[2] == 1:
        return np.repeat(image, 3, axis=2)
    return image[..., :3]


def object_mask(image: np.ndarray) -> np.ndarray:
    return np.max(np.abs(to_rgb(image)), axis=2) > 1e-4


def erode(mask: np.ndarray, iterations: int) -> np.ndarray:
    current = mask.copy()
    for _ in range(iterations):
        shifted = (
            current
            & np.roll(current, 1, axis=0)
            & np.roll(current, -1, axis=0)
            & np.roll(current, 1, axis=1)
            & np.roll(current, -1, axis=1)
        )
        current = shifted
        current[0, :] = False
        current[-1, :] = False
        current[:, 0] = False
        current[:, -1] = False
    return current


def gaussian_kernel(size: int = 11, sigma: float = 1.5) -> np.ndarray:
    x = np.arange(size, dtype=np.float64) - (size - 1) * 0.5
    kernel = np.exp(-(x * x) / (2.0 * sigma * sigma))
    return kernel / kernel.sum()


def blur(image: np.ndarray) -> np.ndarray:
    kernel = gaussian_kernel()
    pad = len(kernel) // 2

    padded = np.pad(image, ((0, 0), (pad, pad)), mode="reflect")
    windows = np.lib.stride_tricks.sliding_window_view(padded, len(kernel), axis=1)
    image = np.einsum("ijk,k->ij", windows, kernel)

    padded = np.pad(image, ((pad, pad), (0, 0)), mode="reflect")
    windows = np.lib.stride_tricks.sliding_window_view(padded, len(kernel), axis=0)
    return np.einsum("ijk,k->ij", windows, kernel)


def ssim(reference: np.ndarray, test: np.ndarray, roi: np.ndarray) -> float:
    # Luminance keeps the metric from being dominated by a single channel.
    ref = 0.2126 * reference[..., 0] + 0.7152 * reference[..., 1] + 0.0722 * reference[..., 2]
    tst = 0.2126 * test[..., 0] + 0.7152 * test[..., 1] + 0.0722 * test[..., 2]

    data_range = max(1.0, float(ref.max()))
    c1 = (0.01 * data_range) ** 2
    c2 = (0.03 * data_range) ** 2

    mu_ref = blur(ref)
    mu_tst = blur(tst)
    sigma_ref = blur(ref * ref) - mu_ref * mu_ref
    sigma_tst = blur(tst * tst) - mu_tst * mu_tst
    sigma_cross = blur(ref * tst) - mu_ref * mu_tst

    numerator = (2.0 * mu_ref * mu_tst + c1) * (2.0 * sigma_cross + c2)
    denominator = (mu_ref * mu_ref + mu_tst * mu_tst + c1) * (sigma_ref + sigma_tst + c2)
    ssim_map = numerator / denominator
    return float(ssim_map[roi].mean()) if roi.any() else float("nan")


def tonemap(image: np.ndarray) -> np.ndarray:
    display = np.clip(image, 0.0, None)
    display = display / (1.0 + display)
    return (np.clip(display, 0.0, 1.0) ** (1.0 / 2.2) * 255.0).astype(np.uint8)


def write_png(reference: np.ndarray, test: np.ndarray, diff: np.ndarray,
              target: Path) -> None:
    from PIL import Image, ImageDraw

    panels = [
        tonemap(to_rgb(reference)),
        tonemap(to_rgb(test)),
        tonemap(diff),
    ]
    separator = np.zeros((panels[0].shape[0], 4, 3), dtype=np.uint8)
    row = panels[0]
    for panel in panels[1:]:
        row = np.concatenate([row, separator, panel], axis=1)
    image = Image.fromarray(row)
    draw = ImageDraw.Draw(image)
    draw.text((8, 8), "reference", fill=(255, 255, 255))
    draw.text((8 + panels[0].shape[1] + 4, 8), "test", fill=(255, 255, 255))
    draw.text((8 + 2 * (panels[0].shape[1] + 4), 8), "|diff| x scale", fill=(255, 255, 255))
    target.parent.mkdir(parents=True, exist_ok=True)
    image.save(target)


def write_exr(array: np.ndarray, target: Path) -> None:
    import mitsuba as mi

    mi.set_variant(os.environ.get("MI_DEFAULT_VARIANT", "metal_ad_rgb"))
    import nx_io

    target.parent.mkdir(parents=True, exist_ok=True)
    nx_io.write_exr(target, mi.Bitmap(np.ascontiguousarray(array.astype(np.float32))))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Compare two linear EXR images.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--reference", required=True, type=Path)
    parser.add_argument("--test", required=True, type=Path)
    parser.add_argument("--mask", default="none", choices=["none", "geometry", "interior"])
    parser.add_argument("--erode", type=int, default=3,
                        help="erosion in pixels for --mask interior (default 3)")
    parser.add_argument("--roi", type=Path,
                        help="EXR whose R channel selects the ROI (e.g. visibility reference)")
    parser.add_argument("--roi-ndotl", action="store_true",
                        help="also require G > 0.5 and B > 0.05 from --roi")
    parser.add_argument("--roi-erode", type=int, default=0,
                        help="erode the selected ROI by N pixels (excludes edge AA)")
    parser.add_argument("--scale", type=float, default=10.0, help="diff amplification")
    parser.add_argument("--out-diff", type=Path, help="linear diff EXR")
    parser.add_argument("--out-png", type=Path, help="tonemapped reference/test/diff PNG")
    parser.add_argument("--json", type=Path, help="write the metrics as JSON")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    prepare_environment()

    try:
        reference = load_image(args.reference)
        test = load_image(args.test)
    except Exception as exc:  # noqa: BLE001 - surface the EXR reader message
        print(f"error: cannot read input: {exc}", file=sys.stderr)
        return 1

    if reference.shape[:2] != test.shape[:2]:
        print(f"error: resolution mismatch: {reference.shape[:2]} vs {test.shape[:2]}",
              file=sys.stderr)
        return 2

    ref_rgb = to_rgb(reference)
    test_rgb = to_rgb(test)
    # Channel counts may differ (a 1-channel visibility image, an RGBA render).
    channels = min(ref_rgb.shape[2], test_rgb.shape[2])
    ref_rgb = ref_rgb[..., :channels]
    test_rgb = test_rgb[..., :channels]

    height, width = ref_rgb.shape[:2]
    all_pixels = np.ones((height, width), dtype=bool)

    roi = all_pixels.copy()
    roi_description = "all pixels"
    if args.roi is not None:
        try:
            roi_image = load_image(args.roi)
        except Exception as exc:  # noqa: BLE001
            print(f"error: cannot read --roi: {exc}", file=sys.stderr)
            return 1
        if roi_image.shape[:2] != (height, width):
            print("error: --roi resolution does not match the images", file=sys.stderr)
            return 2
        roi = roi_image[..., 0] > 0.5
        if args.roi_ndotl:
            if roi_image.shape[2] < 3:
                print("error: --roi-ndotl needs an EXR with at least 3 channels",
                      file=sys.stderr)
                return 2
            roi &= roi_image[..., 1] > 0.5
            roi &= roi_image[..., 2] > 0.05
        roi_description = f"ROI {args.roi}"
        if args.roi_ndotl:
            roi_description += " (object and ndotl filtered)"
    else:
        geometry = object_mask(reference)
        if args.mask == "geometry":
            roi = geometry
            roi_description = "reference geometry"
        elif args.mask == "interior":
            roi = erode(geometry, args.erode)
            roi_description = f"reference geometry eroded by {args.erode}px"

    if not roi.any():
        print("error: the selected ROI is empty", file=sys.stderr)
        return 2

    if args.roi_erode > 0:
        roi = erode(roi, args.roi_erode)
        roi_description += f", eroded by {args.roi_erode}px"
        if not roi.any():
            print("error: the ROI is empty after erosion", file=sys.stderr)
            return 2

    difference = np.abs(ref_rgb - test_rgb)
    mae = float(difference[roi].mean())
    max_abs = float(difference[roi].max())
    mse = float((difference[roi] ** 2).mean())
    psnr = float("inf") if mse <= 0.0 else float(10.0 * np.log10(1.0 / mse))
    ssim_value = ssim(ref_rgb, test_rgb, roi)

    ref_mask = object_mask(reference)
    test_mask = object_mask(test)
    intersection = np.logical_and(ref_mask, test_mask).sum()
    union = np.logical_or(ref_mask, test_mask).sum()
    silhouette_iou = float(intersection / union) if union > 0 else float("nan")

    print(f"reference : {args.reference}")
    print(f"test      : {args.test}")
    print(f"roi       : {roi_description} ({roi.sum()} pixels)")
    print("")
    print(f"PSNR      : {psnr:.6f} dB")
    print(f"SSIM      : {ssim_value:.6f}")
    print(f"MAE       : {mae:.8f}")
    print(f"max abs   : {max_abs:.8f}")
    print(f"silhouette: IoU={silhouette_iou:.6f} coverage ref={ref_mask.mean():.6f} "
          f"test={test_mask.mean():.6f}")

    diff_image = np.abs(ref_rgb - test_rgb) * args.scale
    if args.out_diff is not None:
        write_exr(diff_image, args.out_diff)
        print(f"diff EXR  : {args.out_diff}")
    if args.out_png is not None:
        write_png(reference, test, diff_image, args.out_png)
        print(f"diff PNG  : {args.out_png}")

    if args.json is not None:
        payload = {
            "reference": str(args.reference),
            "test": str(args.test),
            "roi": roi_description,
            "roi_pixels": int(roi.sum()),
            "resolution": [int(width), int(height)],
            "metrics": {
                "psnr_db": psnr,
                "ssim": ssim_value,
                "mae": mae,
                "max_abs": max_abs,
                "silhouette_iou": silhouette_iou,
                "ref_coverage": float(ref_mask.mean()),
                "test_coverage": float(test_mask.mean()),
            },
            "command": " ".join(sys.argv),
        }
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
        print(f"metrics   : {args.json}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
