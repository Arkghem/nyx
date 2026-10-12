#!/usr/bin/env python3
"""Render a reference image with Mitsuba.

The Mitsuba side of nyx is the standard answer everything else is judged
against, so this script deliberately does one thing: load a scene, render it at
a stated sample count and seed, and write a linear HDR EXR. No metrics, no tone
mapping, no image processing — those belong in the comparison scripts, and they
must happen before any tone mapping.

    ./scripts/render_ref.py --scene scenes/stage0_checkerboard.xml \
        --spp 2048 --seed 0 --out references/stage0_checkerboard_metal_2048spp_seed0.exr

Resolution comes from the scene file on purpose: the XML is the single source of
truth for camera and film, so the two renderers cannot drift apart.
"""

from __future__ import annotations

import argparse
import glob
import os
import sys
import time
from pathlib import Path

import nx_io

REPO_ROOT = Path(__file__).resolve().parent.parent

DEFAULT_VARIANT = os.environ.get("MI_DEFAULT_VARIANT", "metal_ad_rgb")


def prepare_environment() -> None:
    """Keep drjit's caches inside the repository.

    drjit writes a JIT cache on first import. Its default location is ~/.drjit,
    which this machine's file sandbox refuses, costing a full recompile on every
    run.
    """
    os.environ.setdefault("DRJIT_CACHE_DIR", str(REPO_ROOT / ".cache" / "drjit"))

    # The llvm_* variants need libLLVM.dylib at import time. The Homebrew
    # formula is the usual source, and it is not on the loader path by default.
    if "DRJIT_LIBLLVM_PATH" not in os.environ:
        candidates = sorted(glob.glob("/opt/homebrew/opt/llvm*/lib/libLLVM.dylib"))
        if candidates:
            os.environ["DRJIT_LIBLLVM_PATH"] = candidates[-1]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Render a Mitsuba reference image to a linear EXR.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--scene", required=False, type=Path, help="Mitsuba scene XML")
    parser.add_argument("--out", type=Path, help="output EXR (default: references/<scene>_<spp>spp_seed<seed>.exr)")
    parser.add_argument("--spp", type=int, default=2048, help="samples per pixel (default 2048)")
    parser.add_argument("--seed", type=int, default=0, help="sampler seed (default 0)")
    parser.add_argument("--variant", default=DEFAULT_VARIANT,
                       help=f"Mitsuba variant (default {DEFAULT_VARIANT})")
    parser.add_argument("--list-variants", action="store_true", help="print available variants and exit")
    return parser.parse_args()


def default_output(scene: Path, variant: str, spp: int, seed: int) -> Path:
    family = variant.split("_")[0]
    return REPO_ROOT / "references" / f"{scene.stem}_{family}_{spp}spp_seed{seed}.exr"


def main() -> int:
    args = parse_args()
    prepare_environment()

    try:
        import mitsuba as mi
    except ImportError as exc:
        print(f"error: cannot import mitsuba ({exc})", file=sys.stderr)
        print("hint : create the environment first — run ./scripts/check_env.py", file=sys.stderr)
        return 1

    if args.list_variants:
        for variant in mi.variants():
            marker = " *" if variant == args.variant else ""
            print(f"  {variant}{marker}")
        return 0

    if args.scene is None:
        print("error: --scene is required (or use --list-variants)", file=sys.stderr)
        return 2
    if not args.scene.exists():
        print(f"error: no scene at {args.scene}", file=sys.stderr)
        return 1

    try:
        mi.set_variant(args.variant)
    except Exception as exc:  # noqa: BLE001 - the message is what matters to the user
        print(f"error: cannot activate variant '{args.variant}': {exc}", file=sys.stderr)
        if args.variant.startswith("llvm"):
            print("hint : llvm variants need DRJIT_LIBLLVM_PATH; see env.sh", file=sys.stderr)
        return 1

    scene = mi.load_file(str(args.scene))

    try:
        film_size = scene.sensors()[0].film().size()
        resolution = (int(film_size[0]), int(film_size[1]))
    except Exception:  # noqa: BLE001 - not every scene exposes a film
        resolution = (0, 0)

    out_path = args.out if args.out else default_output(args.scene, args.variant, args.spp, args.seed)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    print(f"variant   : {mi.variant()} (mitsuba {mi.__version__})")
    print(f"scene     : {args.scene}")
    print(f"resolution: {resolution[0]}x{resolution[1]} (from the scene)")
    print(f"samples   : {args.spp}, seed {args.seed}")
    print("rendering ...")

    start = time.perf_counter()
    image = mi.render(scene, spp=args.spp, seed=args.seed)
    elapsed = time.perf_counter() - start

    import numpy as np

    array = np.asarray(image, dtype=np.float32)
    if not np.isfinite(array).all():
        print("error: the render contains non-finite values", file=sys.stderr)
        return 1

    # nx_io.write_exr drains Mitsuba's task queue; a bare write_bitmap returns
    # before the file exists.
    nx_io.write_exr(out_path, image)

    size_mb = out_path.stat().st_size / (1024 * 1024)
    print("")
    print(f"time      : {elapsed:.2f} s ({args.spp / max(elapsed, 1e-9):.0f} spp/s)")
    print(f"mean      : {array[..., :3].mean():.5f}")
    print(f"output    : {out_path} ({size_mb:.1f} MiB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
