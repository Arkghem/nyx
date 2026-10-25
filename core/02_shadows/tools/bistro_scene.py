#!/usr/bin/env python3
"""Fetch, prepare and export the Amazon Lumberyard Bistro Exterior scene.

The asset is a 61 MiB zip from the G3D data archive containing only
`exterior.obj` and `exterior.mtl`: 2.84M triangles in centimetres, no textures.
That is exactly what a shadow lab wants (a large, self-shadowing scene) and
exactly what the existing exporter did not handle (a text `.nxscene` would be
hundreds of megabytes, and the OBJ contains one invalid vertex normal that makes
Mitsuba reject the whole mesh).

This tool owns the one-time asset preparation:

    fetch     download, verify and extract the zip into third_party/_deps
    prepare   fix the invalid normal and strip the MTL references into
              .cache/assets/bistro/exterior.obj
    scenes    write the tracked Mitsuba XML camera presets
    export    run scripts/export_scene.py --binary for each XML
    all       fetch + prepare + scenes + export
    list      print the camera presets

The cleaned OBJ is still the same geometry as the original; only one zero
normal is replaced by the previous valid normal and the `mtllib`/`usemtl`
lines are dropped so Mitsuba does not try to resolve the 132 MTL materials
(the archive contains no textures for them). Both
renderers therefore use the same triangles and the same flat clay albedo.

Units: the OBJ is in centimetres. Every generated XML applies a 0.01 scale, so
the cameras, lights, clip planes and shadow biases are all in metres.

Usage:
    python3 core/02_shadows/tools/bistro_scene.py all
    ./scripts/run.sh --scene .cache/scenes/bistro_plaza.nxscene --variant sm \
        --cull none --bias 0.001
"""

from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
import math
import os
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
URL = "https://casual-effects.com/g3d/data10/research/model/bistro/Exterior.zip"
ZIP_SHA256 = "f612ba0d8a65811afe0d48a023d31e5b43ac40b78e9b12d15e2b7dc8923c29d4"
ASSET_DIR = REPO_ROOT / "third_party/_deps/bistro"
ZIP_PATH = ASSET_DIR / "Exterior.zip"
RAW_OBJ = ASSET_DIR / "Exterior/exterior.obj"
CLEAN_OBJ = REPO_ROOT / ".cache/assets/bistro/exterior.obj"
MANIFEST = REPO_ROOT / ".cache/assets/bistro/manifest.json"
SCENES_DIR = REPO_ROOT / "core/02_shadows/scenes"
OUT_DIR = REPO_ROOT / ".cache/scenes"

# A direct-only clay render. The G3D archive has no textures, and a constant
# albedo keeps the radiance reference and the realtime pass on the same BSDF.
ALBEDO = (0.62, 0.60, 0.56)
SUN_IRRADIANCE = (5.0, 4.8, 4.4)
SUN_TARGET = (25.0, 3.0, 15.0)
FILM = (1280, 720)
NEAR_CLIP = 0.1
FAR_CLIP = 500.0
SAMPLE_COUNT = 64

# The cameras were chosen by rendering the scene, not by copying the glTF
# benchmark cameras: the G3D OBJ export does not share the glTF scene root, so
# those positions land inside walls. These four views cover the two useful
# shadow cases (eye level and an elevated overview) and a low-sun comparison.
VIEWS = [
    {
        "name": "bistro_plaza",
        "description": "eye level in the plaza, facade, tree and lamp post",
        "origin": (45.0, 2.2, 33.0),
        "target": (30.0, 5.0, 12.0),
        "fov_x": 65.0,
        "sun_azimuth": 55.0,
        "sun_elevation": 35.0,
    },
    {
        "name": "bistro_street",
        "description": "down the street, long facade on the right",
        "origin": (45.0, 2.2, 30.0),
        "target": (-15.0, 5.0, -30.0),
        "fov_x": 70.0,
        "sun_azimuth": 55.0,
        "sun_elevation": 35.0,
    },
    {
        "name": "bistro_overview",
        "description": "elevated oblique overview of the plaza and street",
        "origin": (70.0, 50.0, 75.0),
        "target": (20.0, 0.0, 5.0),
        "fov_x": 60.0,
        "sun_azimuth": 55.0,
        "sun_elevation": 35.0,
    },
    {
        "name": "bistro_plaza_lowsun",
        "description": "same plaza camera with a 25 degree sun",
        "origin": (45.0, 2.2, 33.0),
        "target": (30.0, 5.0, 12.0),
        "fov_x": 65.0,
        "sun_azimuth": 55.0,
        "sun_elevation": 25.0,
    },
]


class BistroError(RuntimeError):
    """A user-facing failure with a next command in the message."""


# ---------------------------------------------------------------------------
# Fetch
# ---------------------------------------------------------------------------


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as file:
        for block in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _content_length(url: str) -> int:
    # The G3D host rejects Python's default urllib User-Agent with 406.
    request = urllib.request.Request(
        url, method="HEAD",
        headers={"User-Agent": "nyx-bistro-fetch/1.0", "Accept": "*/*"},
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        return int(response.headers["Content-Length"])


def _download_range(url: str, start: int, end: int, target: Path) -> None:
    request = urllib.request.Request(
        url,
        headers={
            "Range": f"bytes={start}-{end}",
            "User-Agent": "nyx-bistro-fetch/1.0",
            "Accept": "*/*",
        },
    )
    with urllib.request.urlopen(request, timeout=120) as response:
        if response.status != 206:
            raise BistroError("the server ignored a range request")
        with open(target, "wb") as file:
            shutil.copyfileobj(response, file)
    expected = end - start + 1
    actual = target.stat().st_size
    if actual != expected:
        raise BistroError(f"short range download: {actual} of {expected} bytes")


def download(url: str, target: Path, expected_sha256: str, jobs: int) -> None:
    if target.exists() and sha256_file(target) == expected_sha256:
        print(f"  zip already present and verified: {target}")
        return

    target.parent.mkdir(parents=True, exist_ok=True)
    total = _content_length(url)
    print(f"  url   : {url}")
    print(f"  bytes : {total} ({total / (1024 * 1024):.1f} MiB)")
    if total <= 0:
        raise BistroError("the server returned an empty file")

    chunk = (total + jobs - 1) // jobs
    parts = []
    for index in range(jobs):
        start = index * chunk
        end = min(start + chunk - 1, total - 1)
        if start > end:
            break
        parts.append((index, start, end, target.with_name(f"{target.name}.part{index}")))

    print(f"  ranges: {len(parts)} parallel connections")
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(parts)) as pool:
        futures = {
            pool.submit(_download_range, url, start, end, path): index
            for index, start, end, path in parts
        }
        done = 0
        for future in concurrent.futures.as_completed(futures):
            future.result()
            done += 1
            print(f"  part {done}/{len(parts)} done", end="\r", flush=True)
    print("")

    with open(target, "wb") as output:
        for _, _, _, path in parts:
            with open(path, "rb") as part:
                shutil.copyfileobj(part, output)
            path.unlink()

    actual = sha256_file(target)
    if actual != expected_sha256:
        target.unlink(missing_ok=True)
        raise BistroError(
            f"sha256 mismatch\nexpected {expected_sha256}\nactual   {actual}"
        )
    print(f"  sha256: {actual}")


def fetch(force: bool, jobs: int) -> None:
    print("Bistro fetch")
    if force and ZIP_PATH.exists():
        ZIP_PATH.unlink()
    ASSET_DIR.mkdir(parents=True, exist_ok=True)
    download(URL, ZIP_PATH, ZIP_SHA256, jobs)

    wanted = {"exterior.obj", "exterior.mtl"}
    if (RAW_OBJ.exists() and
            RAW_OBJ.stat().st_mtime >= ZIP_PATH.stat().st_mtime):
        print(f"  extracted asset is current: {RAW_OBJ}")
        return
    print(f"  extract: {ASSET_DIR / 'Exterior'}")
    with zipfile.ZipFile(ZIP_PATH) as archive:
        names = {name for name in archive.namelist() if Path(name).name in wanted}
        if names != wanted:
            raise BistroError(f"unexpected zip contents: {sorted(archive.namelist())}")
        for name in names:
            archive.extract(name, ASSET_DIR / "Exterior")
    print(f"  obj   : {RAW_OBJ} ({RAW_OBJ.stat().st_size / (1024 * 1024):.1f} MiB)")


# ---------------------------------------------------------------------------
# Prepare
# ---------------------------------------------------------------------------


def prepare(force: bool) -> None:
    print("Bistro prepare")
    if not RAW_OBJ.exists():
        raise BistroError(f"no raw OBJ at {RAW_OBJ}; run `bistro_scene.py fetch` first")
    if (CLEAN_OBJ.exists() and not force
            and CLEAN_OBJ.stat().st_mtime >= RAW_OBJ.stat().st_mtime):
        print(f"  clean OBJ is newer than the download, skipping: {CLEAN_OBJ}")
        return

    CLEAN_OBJ.parent.mkdir(parents=True, exist_ok=True)
    tmp = CLEAN_OBJ.with_suffix(".obj.tmp")
    minimum = [float("inf")] * 3
    maximum = [float("-inf")] * 3
    vertices = 0
    normals = 0
    triangles = 0
    fixed = 0
    last_normal = (0.0, 0.0, 1.0)

    with open(RAW_OBJ, "rb") as source, open(tmp, "wb") as output:
        for line in source:
            # Mitsuba would try to resolve the 132 MTL materials, none of whose
            # textures are in the archive. The XML supplies one clay BSDF instead.
            if line.startswith(b"mtllib ") or line.startswith(b"usemtl "):
                continue
            if line.startswith(b"v "):
                parts = line.split()
                values = (float(parts[1]), float(parts[2]), float(parts[3]))
                for axis, value in enumerate(values):
                    minimum[axis] = min(minimum[axis], value)
                    maximum[axis] = max(maximum[axis], value)
                vertices += 1
                output.write(line)
            elif line.startswith(b"vn "):
                parts = line.split()
                values = tuple(float(parts[i]) for i in (1, 2, 3))
                length_squared = sum(value * value for value in values)
                if not math.isfinite(length_squared) or length_squared < 1e-20:
                    fixed += 1
                    values = last_normal
                    output.write(
                        f"vn {values[0]:.6f} {values[1]:.6f} {values[2]:.6f}\n".encode()
                    )
                else:
                    last_normal = values
                    output.write(line)
                normals += 1
            else:
                if line.startswith(b"f "):
                    triangles += 1
                output.write(line)

    if vertices == 0 or normals == 0 or triangles == 0:
        tmp.unlink(missing_ok=True)
        raise BistroError(
            "the sanitized OBJ lost a whole record type "
            f"(vertices={vertices}, normals={normals}, triangles={triangles})"
        )

    tmp.replace(CLEAN_OBJ)
    manifest = {
        "source": str(RAW_OBJ.relative_to(REPO_ROOT)),
        "source_zip_sha256": sha256_file(ZIP_PATH),
        "clean": str(CLEAN_OBJ.relative_to(REPO_ROOT)),
        "clean_sha256": sha256_file(CLEAN_OBJ),
        "vertices": vertices,
        "vertex_normals": normals,
        "triangles": triangles,
        "fixed_normals": fixed,
        "bounds_cm_min": minimum,
        "bounds_cm_max": maximum,
        "bounds_m_min": [value * 0.01 for value in minimum],
        "bounds_m_max": [value * 0.01 for value in maximum],
        "note": (
            "Flat albedo; MTL references removed because the G3D archive has no "
            "textures. One invalid normal replaced by the previous valid normal."
        ),
    }
    MANIFEST.parent.mkdir(parents=True, exist_ok=True)
    MANIFEST.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

    print(f"  clean : {CLEAN_OBJ} ({CLEAN_OBJ.stat().st_size / (1024 * 1024):.1f} MiB)")
    print(f"  mesh  : {vertices} vertices, {normals} normals, {triangles} triangles")
    print(f"  fixed : {fixed} invalid normal(s)")
    print(f"  bounds: {manifest['bounds_m_min']} .. {manifest['bounds_m_max']} m")
    print(f"  manifest: {MANIFEST}")


# ---------------------------------------------------------------------------
# Scene XML
# ---------------------------------------------------------------------------


def sun_position(azimuth_degrees: float, elevation_degrees: float,
                 distance: float = 200.0) -> tuple[float, float, float]:
    """Sun position for a Mitsuba directional emitter.

    A directional emitter's local +Z is its propagation direction, and
    `<lookat origin=... target=...>` points that axis at the target. Azimuth 0
    therefore places the sun on +Z, azimuth 90 on +X.
    """
    azimuth = math.radians(azimuth_degrees)
    elevation = math.radians(elevation_degrees)
    horizontal = math.cos(elevation) * distance
    return (
        SUN_TARGET[0] + horizontal * math.sin(azimuth),
        SUN_TARGET[1] + math.sin(elevation) * distance,
        SUN_TARGET[2] + horizontal * math.cos(azimuth),
    )


def scene_xml(view: dict) -> str:
    origin = view["origin"]
    target = view["target"]
    sun = sun_position(view["sun_azimuth"], view["sun_elevation"])
    rel_obj = os.path.relpath(CLEAN_OBJ, SCENES_DIR).replace(os.sep, "/")
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<!--
  Bistro Exterior — {view['description']}.

  Generated by core/02_shadows/tools/bistro_scene.py. The tracked XML is what
  scripts/export_scene.py reads, so edit this file (or the view table in the
  tool and regenerate with its force flag) before changing the camera.

  Geometry: {rel_obj}
  The source OBJ is in centimetres; <scale value="0.01"/> puts the whole scene
  in metres, matching the camera, clip planes and shadow bias.

  The G3D archive has no textures. A constant reflectance is used on purpose:
  shadow metrics must not depend on texture filtering, and both Mitsuba and the
  realtime pass then shade the same BSDF.

  The emitter's local +Z is the propagation direction (Mitsuba convention);
  the realtime pass receives the same direction and irradiance from the
  exporter.
-->
<scene version="3.0.0">
    <integrator type="direct"/>

    <sensor type="perspective">
        <float name="fov" value="{view['fov_x']}"/>
        <float name="near_clip" value="{NEAR_CLIP}"/>
        <float name="far_clip" value="{FAR_CLIP}"/>
        <transform name="to_world">
            <lookat origin="{origin[0]}, {origin[1]}, {origin[2]}"
                    target="{target[0]}, {target[1]}, {target[2]}"
                    up="0, 1, 0"/>
        </transform>
        <film type="hdrfilm">
            <integer name="width" value="{FILM[0]}"/>
            <integer name="height" value="{FILM[1]}"/>
            <string name="pixel_format" value="rgb"/>
            <string name="component_format" value="float32"/>
            <rfilter type="box"/>
        </film>
        <sampler type="independent">
            <integer name="sample_count" value="{SAMPLE_COUNT}"/>
        </sampler>
    </sensor>

    <shape type="obj">
        <string name="filename" value="{rel_obj}"/>
        <transform name="to_world">
            <scale value="0.01"/>
        </transform>
        <bsdf type="diffuse">
            <rgb name="reflectance" value="{ALBEDO[0]}, {ALBEDO[1]}, {ALBEDO[2]}"/>
        </bsdf>
    </shape>

    <emitter type="directional">
        <rgb name="irradiance" value="{SUN_IRRADIANCE[0]}, {SUN_IRRADIANCE[1]}, {SUN_IRRADIANCE[2]}"/>
        <transform name="to_world">
            <lookat origin="{sun[0]:.4f}, {sun[1]:.4f}, {sun[2]:.4f}"
                    target="{SUN_TARGET[0]}, {SUN_TARGET[1]}, {SUN_TARGET[2]}"
                    up="0, 1, 0"/>
        </transform>
    </emitter>
</scene>
"""


def scenes(force: bool) -> None:
    print("Bistro scenes")
    if not CLEAN_OBJ.exists():
        raise BistroError(f"no clean OBJ at {CLEAN_OBJ}; run `bistro_scene.py prepare` first")
    SCENES_DIR.mkdir(parents=True, exist_ok=True)
    for view in VIEWS:
        path = SCENES_DIR / f"{view['name']}.xml"
        if path.exists() and not force:
            print(f"  keep  : {path}")
            continue
        path.write_text(scene_xml(view), encoding="utf-8")
        print(f"  write : {path}")


# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------


def export() -> None:
    print("Bistro export")
    if not CLEAN_OBJ.exists():
        raise BistroError(f"no clean OBJ at {CLEAN_OBJ}; run `bistro_scene.py prepare` first")
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for view in VIEWS:
        xml = SCENES_DIR / f"{view['name']}.xml"
        if not xml.exists():
            raise BistroError(f"no scene XML at {xml}; run `bistro_scene.py scenes` first")
        result = subprocess.run(
            [sys.executable, "scripts/export_scene.py", "--binary",
             "--scene", str(xml), "--out-dir", str(OUT_DIR)],
            cwd=REPO_ROOT,
            text=True,
            capture_output=True,
        )
        if result.returncode != 0:
            sys.stderr.write(result.stdout)
            sys.stderr.write(result.stderr)
            raise BistroError(f"exporter failed for {xml}")
        # Keep the summary line, drop the noisy header.
        for line in result.stdout.splitlines():
            if line.strip().startswith("[ok") or "->" in line:
                print(line)
        nxscene = OUT_DIR / f"{view['name']}.nxscene"
        if not nxscene.exists():
            raise BistroError(f"exporter did not write {nxscene}")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def list_views() -> None:
    print("Bistro Exterior camera presets")
    for view in VIEWS:
        print(f"  {view['name']:22s} {view['description']}")
        print(
            f"      origin=({view['origin'][0]:g}, {view['origin'][1]:g}, {view['origin'][2]:g}) "
            f"target=({view['target'][0]:g}, {view['target'][1]:g}, {view['target'][2]:g}) "
            f"fov_x={view['fov_x']:g}"
        )
        print(
            f"      sun az={view['sun_azimuth']:g} el={view['sun_elevation']:g} "
            f"irradiance={SUN_IRRADIANCE}"
        )
    print("")
    print("Run one with:")
    print("  ./scripts/run.sh --scene .cache/scenes/bistro_plaza.nxscene "
          "--variant sm --cull none --bias 0.001")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Bistro Exterior asset and scene scaffolding.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "command",
        choices=["fetch", "prepare", "scenes", "export", "all", "list"],
        help="action to perform",
    )
    parser.add_argument("--force", action="store_true",
                        help="re-download, re-sanitize or overwrite generated XMLs")
    parser.add_argument("--jobs", type=int, default=8,
                        help="parallel range downloads (default 8)")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        if args.command == "list":
            list_views()
            return 0
        if args.command in ("fetch", "all"):
            fetch(args.force, max(1, args.jobs))
        if args.command in ("prepare", "all"):
            prepare(args.force)
        if args.command in ("scenes", "all"):
            scenes(args.force)
        if args.command in ("export", "all"):
            export()
        if args.command == "all":
            print("")
            print("Rendered with:")
            print("  ./scripts/run.sh --scene .cache/scenes/bistro_plaza.nxscene "
                  "--variant sm --cull none --bias 0.001")
        return 0
    except BistroError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    except (OSError, urllib.error.URLError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
