#!/usr/bin/env python3
"""Environment self-check for nyx.

Reports PASS / FAIL / WARN / INFO for every prerequisite and reflects the result
in the exit code. It installs nothing and changes no configuration: a check that
silently fixes things cannot tell you what was broken.

    ./scripts/check_env.py

Exit codes: 0 = no failures, 1 = at least one FAIL.
"""

from __future__ import annotations

import argparse
import glob
import importlib
import os
import shutil
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

# Revision of The-Forge this lab is pinned to. Update together with
# .gitmodules.
FORGE_PIN = "cd5046893faba2dc7869243873bf01f02a6f0df9"

PASS = "PASS"
FAIL = "FAIL"
WARN = "WARN"
INFO = "INFO"

_results: list[tuple[str, str, str]] = []


def record(status: str, name: str, detail: str = "") -> None:
    _results.append((status, name, detail))
    suffix = f"  ({detail})" if detail else ""
    print(f"  [{status}] {name}{suffix}")


def section(title: str) -> None:
    print("")
    print(title)


def run(command: list[str]) -> tuple[int, str]:
    """Runs a command, returning (returncode, combined output). Never raises."""
    try:
        completed = subprocess.run(
            command, capture_output=True, text=True, timeout=60, check=False
        )
        output = (completed.stdout or "") + (completed.stderr or "")
        return completed.returncode, output.strip()
    except (OSError, subprocess.SubprocessError) as exc:
        return 127, str(exc)


# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------


def check_interpreter() -> None:
    section("Interpreter")
    version = sys.version_info
    record(INFO, f"running under {sys.executable}")
    if version >= (3, 10):
        record(PASS, f"python {version.major}.{version.minor}.{version.micro}")
    elif version >= (3, 9):
        record(WARN, f"python {version.major}.{version.minor} is old",
               "mitsuba works, but prefer the 3.12 virtual environment")
    else:
        record(FAIL, f"python {version.major}.{version.minor} is too old", "need >= 3.10")

    venv = REPO_ROOT / ".venv"
    if venv.is_dir():
        record(PASS, "project virtual environment exists", str(venv))
        if Path(sys.executable).resolve().is_relative_to(venv.resolve()):
            record(PASS, "check_env.py is running inside it")
        else:
            record(WARN, "check_env.py is not running inside .venv",
                   f"try {venv / 'bin' / 'python3'} scripts/check_env.py")
    else:
        record(WARN, "no .venv yet", "uv venv --python 3.12 .venv && uv pip install -e .")


def check_packages() -> None:
    section("Python packages")
    required = {
        "numpy": "arrays everywhere",
        "mitsuba": "reference renderer",
    }
    soon = {
        "scipy": "gather/scatter helpers for the metrics scripts",
        "imageio": "diff images and PNG reports",
        "skimage": "SSIM (single implementation, python side)",
    }
    optional = {
        "cv2": "image inspection",
        "pytest": "regression gates",
        "tqdm": "progress bars on long renders",
        "torch": "stage 8, differentiable rendering",
    }

    for name, why in required.items():
        try:
            module = importlib.import_module(name)
            record(PASS, f"{name} {getattr(module, '__version__', '')}".strip())
        except Exception as exc:  # noqa: BLE001
            record(FAIL, f"{name} missing", f"{why}: {type(exc).__name__}")

    for name, why in soon.items():
        try:
            module = importlib.import_module(name)
            record(PASS, f"{name} {getattr(module, '__version__', '')}".strip())
        except Exception:  # noqa: BLE001
            record(WARN, f"{name} not installed yet", why)

    for name, why in optional.items():
        try:
            module = importlib.import_module(name)
            record(PASS, f"{name} {getattr(module, '__version__', '')}".strip())
        except Exception:  # noqa: BLE001
            record(INFO, f"{name} not installed", why)


def check_mitsuba() -> None:
    section("Mitsuba")
    try:
        import mitsuba as mi
    except Exception as exc:  # noqa: BLE001
        record(FAIL, "mitsuba import", str(exc))
        return

    record(PASS, f"mitsuba {mi.__version__}")

    variants = list(mi.variants())
    has_cuda = any("cuda" in variant for variant in variants)
    has_metal = any(variant.startswith("metal") for variant in variants)
    record(INFO, f"{len(variants)} variants, cuda={has_cuda}, metal={has_metal}",
           "no cuda on macOS is expected; metal uses the ray tracing hardware")

    target = os.environ.get("MI_DEFAULT_VARIANT", "metal_ad_rgb")
    if target not in variants:
        record(FAIL, f"variant '{target}' is not available")
        return
    try:
        mi.set_variant(target)
        record(PASS, f"variant '{target}' activates")
    except Exception as exc:  # noqa: BLE001
        record(FAIL, f"variant '{target}' fails to activate", str(exc))
        return

    llvm_dylib = os.environ.get("DRJIT_LIBLLVM_PATH", "")
    if llvm_dylib:
        record(PASS, "DRJIT_LIBLLVM_PATH set", llvm_dylib)
        if not Path(llvm_dylib).exists():
            record(FAIL, "DRJIT_LIBLLVM_PATH points at nothing", llvm_dylib)
    else:
        found = sorted(glob.glob("/opt/homebrew/opt/llvm*/lib/libLLVM.dylib"))
        if found:
            record(WARN, "DRJIT_LIBLLVM_PATH not set", f"source env.sh; found {found[-1]}")
        else:
            record(INFO, "no libLLVM.dylib found", "llvm_* variants will not activate")

    if "llvm_ad_rgb" in variants and llvm_dylib and Path(llvm_dylib).exists():
        try:
            mi.set_variant("llvm_ad_rgb")
            record(PASS, "variant 'llvm_ad_rgb' activates")
            mi.set_variant(target)
        except Exception as exc:  # noqa: BLE001
            record(FAIL, "variant 'llvm_ad_rgb' fails to activate", str(exc))

    # EXR round trip: the whole judging loop depends on linear EXR files.
    smoke_dir = REPO_ROOT / "references" / "_smoke"
    smoke_dir.mkdir(parents=True, exist_ok=True)
    smoke_path = smoke_dir / "check_env.exr"
    try:
        import numpy as np

        import nx_io

        bitmap = mi.Bitmap(np.zeros((32, 32, 3), dtype=np.float32) + 0.25)
        # nx_io.write_exr synchronises with Mitsuba's task pool first: a bare
        # write_bitmap returns before the file exists, which reads exactly like
        # a sandbox permission problem.
        nx_io.write_exr(smoke_path, bitmap)
        record(PASS, "EXR written and settled", f"{smoke_path.stat().st_size} bytes")

        restored = nx_io.load_exr(smoke_path)
        if restored.shape[0] == 32 and restored.shape[1] == 32:
            record(PASS, "EXR read back", f"{restored.shape}")
        else:
            record(FAIL, "EXR read back has the wrong shape", f"{restored.shape}")
    except Exception as exc:  # noqa: BLE001
        record(FAIL, "EXR round trip failed", f"{type(exc).__name__}: {exc}")


def check_layout() -> None:
    section("Repository layout")
    for relative in ("core", "libs", "scripts", "cmake", "third_party",
                     "scenes", "references", "outputs", "reports", "docs", "patches"):
        path = REPO_ROOT / relative
        if path.is_dir():
            record(PASS, f"{relative}/")
        else:
            record(FAIL, f"{relative}/ missing")

    cache = os.environ.get("DRJIT_CACHE_DIR", "")
    if not cache:
        record(WARN, "DRJIT_CACHE_DIR not set", "source env.sh; drjit would write to ~/.drjit")
    elif Path(cache).resolve().is_relative_to(REPO_ROOT):
        record(PASS, "DRJIT_CACHE_DIR is inside the repository", cache)
    else:
        record(FAIL, "DRJIT_CACHE_DIR is outside the repository", f"{cache} — the sandbox denies writes there")


def check_toolchain() -> None:
    section("Toolchain")

    cmake = os.environ.get("NX_CMAKE") or shutil.which("cmake")
    if cmake:
        code, output = run([cmake, "--version"])
        version = output.splitlines()[0] if output else "unknown"
        if cmake.startswith("/opt/homebrew"):
            record(PASS, f"cmake at {cmake}", version)
        else:
            # A stale python-installed cmake can shadow the Homebrew one; env.sh
            # prepends /opt/homebrew/bin to PATH to prevent exactly this.
            record(WARN, f"cmake resolves to {cmake}",
                   "source env.sh so NX_CMAKE points at /opt/homebrew/bin/cmake")
    else:
        record(FAIL, "cmake not found")

    if shutil.which("ninja"):
        record(PASS, "ninja available")
    else:
        record(INFO, "ninja not installed", "CMakePresets.json uses Unix Makefiles instead")

    xcodebuild = shutil.which("xcodebuild")
    if xcodebuild:
        code, output = run([xcodebuild, "-version"])
        record(PASS, "xcodebuild", output.splitlines()[0] if output else "")
    else:
        record(FAIL, "xcodebuild not found", "needed for The-Forge")

    for tool in ("metal", "metallib"):
        code, output = run(["xcrun", "-sdk", "macosx", "--find", tool])
        if code == 0 and output:
            record(PASS, f"Metal toolchain: {tool}")
        else:
            record(FAIL, f"Metal toolchain: {tool} missing", "install it from Xcode settings")


def check_forge() -> None:
    section("The-Forge")
    forge = REPO_ROOT / "forge"

    if not forge.is_dir():
        record(WARN, "forge/ not present",
               "git submodule add https://github.com/ConfettiFX/The-Forge.git forge")
        return

    gitmodules = REPO_ROOT / ".gitmodules"
    if gitmodules.exists() and "forge" in gitmodules.read_text(encoding="utf-8", errors="replace"):
        record(PASS, "forge/ is declared as a submodule")
    else:
        record(WARN, "forge/ is not a declared submodule", "add it via git submodule add")

    code, output = run(["git", "-C", str(forge), "rev-parse", "HEAD"])
    if code == 0:
        head = output.strip()
        if head == FORGE_PIN:
            record(PASS, f"pinned at {head[:12]}")
        else:
            record(WARN, f"HEAD is {head[:12]}, expected {FORGE_PIN[:12]}",
                   "check out the pin, or update FORGE_PIN in this script and in .gitmodules")
    else:
        record(FAIL, "cannot read forge/ HEAD", output)

    libraries = list(forge.glob("Examples_3/Unit_Tests/macOS_Xcode/The-Forge/Bin/*/libThe-Forge.a"))
    if libraries:
        record(PASS, "libThe-Forge.a built", str(libraries[0]))
    else:
        record(WARN, "libThe-Forge.a not built yet", "./scripts/build_forge.sh")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--verbose", action="store_true", help="also list passing optional checks")
    args = parser.parse_args()

    print("nyx environment check")
    print("=====================")

    check_interpreter()
    check_layout()
    check_packages()
    check_mitsuba()
    check_toolchain()
    check_forge()

    failures = [entry for entry in _results if entry[0] == FAIL]
    warnings = [entry for entry in _results if entry[0] == WARN]

    print("")
    print("=====================")
    print(f"{len(_results)} checks: "
          f"{len([e for e in _results if e[0] == PASS])} pass, "
          f"{len(failures)} fail, {len(warnings)} warn")

    if failures:
        print("")
        print("failures:")
        for _, name, detail in failures:
            print(f"  - {name}" + (f" ({detail})" if detail else ""))
    if warnings:
        print("")
        print("warnings:")
        for _, name, detail in warnings:
            print(f"  - {name}" + (f" ({detail})" if detail else ""))

    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
