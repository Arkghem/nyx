#!/usr/bin/env python3
"""Independent visibility reference for 02_shadows.

Why an independent ray caster
-----------------------------
Mitsuba gives the radiance reference, but the question "did the shadow map put
this pixel in shadow?" is easier to answer on a visibility image: no lighting
model, no filtering, no tone mapping. This tool rasterizes nothing: it traces
one primary ray per pixel and shadow rays against the exact same world-space
triangles the GPU renderer consumes, so it shares the scene export but none of
the GPU code.

Output channels (linear, float32 EXR)
    R: visibility (1 lit, 0 occluded, 1 on background)
    G: object mask (1 where the primary ray hit geometry)
    B: max(dot(normal, -light_direction), 0), the receiver's lighting term
    A: 1

The B channel is what lets the metrics exclude back-facing pixels: a visibility
comparison on a surface that faces away from the light is meaningless.

Usage
-----
    python3 core/02_shadows/tools/raycast_ref.py \
        --scene .cache/scenes/shadow_basic.nxscene \
        --out references/_smoke/shadow_basic_mask.exr

For a directional light the result is exact (one shadow ray). For a rectangular
area light the tool averages `--spp` stratified shadow rays; it is much slower
and is meant for the soft-shadow scenes, not for every run.

This script deliberately has no GPU dependency. It imports Mitsuba only to write
the EXR (nyx's single image I/O path), which is why the environment setup below
looks like scripts/render_ref.py's.
"""

from __future__ import annotations

import argparse
import glob
import math
import os
import sys
import time
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


def write_exr(path: Path, image: np.ndarray) -> None:
    """Write through nx_io so the Mitsuba write is actually drained."""
    import mitsuba as mi

    mi.set_variant(os.environ.get("MI_DEFAULT_VARIANT", "metal_ad_rgb"))
    import nx_io

    path.parent.mkdir(parents=True, exist_ok=True)
    nx_io.write_exr(path, mi.Bitmap(np.ascontiguousarray(image.astype(np.float32))))


# ---------------------------------------------------------------------------
# .nxscene parsing (kept in sync with src/scene.cpp)
# ---------------------------------------------------------------------------


class SceneError(RuntimeError):
    pass


def parse_nxscene(path: Path) -> dict:
    lines = path.read_text(encoding="utf-8").splitlines()
    camera = None
    film = (0, 0)
    lights = []
    meshes = []
    saw_header = False
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        i += 1
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        token = parts[0]
        if token == "nxscene":
            if len(parts) != 2 or parts[1] != "1":
                raise SceneError(
                    "this CPU ray caster only supports inline-triangle nxscene 1 "
                    "files. Bistro exports nxscene 2 with a .nxmesh sidecar; use the "
                    "Mitsuba radiance reference (scripts/render_ref.py) instead."
                )
            saw_header = True
        elif token == "meshfile":
            raise SceneError(
                "meshfile scenes are outside this tool's budget: it brute-forces "
                "every triangle in numpy. Use scripts/render_ref.py for Bistro."
            )
        elif token == "film":
            film = (int(parts[1]), int(parts[2]))
        elif token == "camera":
            values = np.asarray([float(x) for x in parts[1:]], dtype=np.float64)
            if values.size != 16:
                raise SceneError("camera line needs 16 numbers")
            camera = {
                "origin": values[0:3],
                "right": values[3:6],
                "up": values[6:9],
                "forward": values[9:12],
                "fov_x": values[12],
                "fov_y": values[13],
                "near": values[14],
                "far": values[15],
            }
        elif token == "light":
            kind = parts[1]
            values = np.asarray([float(x) for x in parts[2:]], dtype=np.float64)
            if kind == "directional":
                lights.append(
                    {
                        "kind": "directional",
                        "direction": normalize(values[0:3]),
                        "irradiance": values[3:6],
                    }
                )
            elif kind == "area":
                if values.size != 15:
                    raise SceneError("area light line needs 15 numbers")
                lights.append(
                    {
                        "kind": "area",
                        "radiance": values[0:3],
                        "corners": values[3:15].reshape(4, 3),
                    }
                )
            else:
                raise SceneError(f"unknown light kind '{kind}'")
        elif token == "mesh":
            if len(parts) != 5:
                raise SceneError("mesh line needs albedo and a triangle count")
            albedo = [float(x) for x in parts[1:4]]
            count = int(parts[4])
            positions = []
            normals = []
            for _ in range(count):
                triangle_parts = lines[i].split()
                i += 1
                if not triangle_parts or triangle_parts[0] != "tri":
                    raise SceneError("expected a tri line inside a mesh")
                values = np.asarray([float(x) for x in triangle_parts[1:]], dtype=np.float64)
                if values.size != 18:
                    raise SceneError("tri line needs 18 numbers")
                positions.append(values[0:9].reshape(3, 3))
                normals.append(values[9:18].reshape(3, 3))
            meshes.append(
                {
                    "albedo": np.asarray(albedo),
                    "positions": np.asarray(positions),  # (T, 3, 3)
                    "normals": np.asarray(normals),      # (T, 3, 3)
                }
            )
        else:
            raise SceneError(f"unknown token '{token}'")

    if not saw_header:
        raise SceneError("missing 'nxscene 1' header")
    if camera is None:
        raise SceneError("missing camera")
    if film[0] <= 0 or film[1] <= 0:
        raise SceneError("missing film size")
    if not meshes:
        raise SceneError("no geometry")
    if not lights:
        raise SceneError("no lights")
    return {"camera": camera, "film": film, "lights": lights, "meshes": meshes}


def normalize(vector: np.ndarray) -> np.ndarray:
    length = float(np.linalg.norm(vector))
    if length < 1e-12:
        raise SceneError("degenerate vector in scene")
    return vector / length


# ---------------------------------------------------------------------------
# Ray casting
# ---------------------------------------------------------------------------


def camera_rays(camera: dict, width: int, height: int) -> tuple[np.ndarray, np.ndarray]:
    xs = (np.arange(width, dtype=np.float64) + 0.5) / width * 2.0 - 1.0
    ys = 1.0 - (np.arange(height, dtype=np.float64) + 0.5) / height * 2.0
    ndc_x, ndc_y = np.meshgrid(xs, ys)

    tan_x = math.tan(math.radians(camera["fov_x"]) * 0.5)
    tan_y = math.tan(math.radians(camera["fov_y"]) * 0.5)

    directions = (
        camera["forward"][None, None, :]
        + camera["right"][None, None, :] * (ndc_x[..., None] * tan_x)
        + camera["up"][None, None, :] * (ndc_y[..., None] * tan_y)
    )
    directions = directions.reshape(-1, 3)
    directions /= np.linalg.norm(directions, axis=1, keepdims=True)

    origins = np.broadcast_to(camera["origin"], directions.shape).copy()
    return origins, directions


def nearest_hits(origins: np.ndarray, directions: np.ndarray, positions: np.ndarray,
                 chunk: int = 100_000) -> tuple[np.ndarray, np.ndarray]:
    """Closest triangle per ray. Returns (triangle index, t); index -1 for a miss."""
    ray_count = origins.shape[0]
    triangle_count = positions.shape[0]
    edge1 = positions[:, 1] - positions[:, 0]
    edge2 = positions[:, 2] - positions[:, 0]

    best_t = np.full(ray_count, np.inf, dtype=np.float64)
    best_triangle = np.full(ray_count, -1, dtype=np.int32)

    for start in range(0, ray_count, chunk):
        end = min(start + chunk, ray_count)
        ray_origins = origins[start:end]
        ray_directions = directions[start:end]
        local_best_t = best_t[start:end]
        local_best_triangle = best_triangle[start:end]

        for triangle in range(triangle_count):
            v0 = positions[triangle, 0]
            e1 = edge1[triangle]
            e2 = edge2[triangle]
            h = np.cross(ray_directions, e2)
            a = h @ e1
            with np.errstate(divide="ignore", invalid="ignore"):
                f = 1.0 / a
            s = ray_origins - v0
            u = f * np.einsum("ij,ij->i", s, h)
            q = np.cross(s, e1)
            v = f * np.einsum("ij,ij->i", ray_directions, q)
            t = f * (q @ e2)
            valid = (
                (np.abs(a) > 1e-12)
                & (u >= -1e-6)
                & (u <= 1.0 + 1e-6)
                & (v >= -1e-6)
                & (u + v <= 1.0 + 1e-6)
                & (t > 1e-5)
            )
            better = valid & (t < local_best_t)
            local_best_t[better] = t[better]
            local_best_triangle[better] = triangle

        best_t[start:end] = local_best_t
        best_triangle[start:end] = local_best_triangle

    return best_triangle, best_t


def any_occlusion(origins: np.ndarray, directions: np.ndarray, positions: np.ndarray,
                  max_t: np.ndarray | None = None, chunk: int = 100_000) -> np.ndarray:
    """True where a shadow ray hits any triangle."""
    ray_count = origins.shape[0]
    triangle_count = positions.shape[0]
    edge1 = positions[:, 1] - positions[:, 0]
    edge2 = positions[:, 2] - positions[:, 0]
    occluded = np.zeros(ray_count, dtype=bool)

    for start in range(0, ray_count, chunk):
        end = min(start + chunk, ray_count)
        ray_origins = origins[start:end]
        ray_directions = directions[start:end]
        local_occluded = np.zeros(end - start, dtype=bool)
        local_max_t = max_t[start:end] if max_t is not None else None

        for triangle in range(triangle_count):
            v0 = positions[triangle, 0]
            e1 = edge1[triangle]
            e2 = edge2[triangle]
            h = np.cross(ray_directions, e2)
            a = h @ e1
            with np.errstate(divide="ignore", invalid="ignore"):
                f = 1.0 / a
            s = ray_origins - v0
            u = f * np.einsum("ij,ij->i", s, h)
            q = np.cross(s, e1)
            v = f * np.einsum("ij,ij->i", ray_directions, q)
            t = f * (q @ e2)
            valid = (
                (np.abs(a) > 1e-12)
                & (u >= -1e-6)
                & (u <= 1.0 + 1e-6)
                & (v >= -1e-6)
                & (u + v <= 1.0 + 1e-6)
                & (t > 1e-4)
            )
            if local_max_t is not None:
                valid &= t < local_max_t
            local_occluded |= valid

        occluded[start:end] = local_occluded

    return occluded


# ---------------------------------------------------------------------------
# Reference construction
# ---------------------------------------------------------------------------


def area_light_samples(corners: np.ndarray, count: int, rng: np.random.Generator) -> np.ndarray:
    # Stratified bilinear samples on the quad. The corner order is a loop around
    # the polygon, so bilinear interpolation covers the rectangle.
    u = (np.arange(count, dtype=np.float64) + rng.random(count)) / count
    v = (np.arange(count, dtype=np.float64) + rng.random(count)) / count
    u = u[:, None]
    v = v[:, None]
    return (
        (1.0 - u) * (1.0 - v) * corners[0]
        + u * (1.0 - v) * corners[1]
        + u * v * corners[2]
        + (1.0 - u) * v * corners[3]
    )


def build_reference(scene: dict, width: int, height: int, spp: int,
                    seed: int) -> tuple[np.ndarray, dict]:
    camera = scene["camera"]
    positions = np.concatenate([mesh["positions"] for mesh in scene["meshes"]], axis=0)
    normals = np.concatenate([mesh["normals"] for mesh in scene["meshes"]], axis=0)

    origins, directions = camera_rays(camera, width, height)
    triangle_index, distance = nearest_hits(origins, directions, positions)
    hit = triangle_index >= 0

    # Flat-face scenes dominate the lab; the first vertex normal is exact on
    # those and a reasonable approximation on a smooth OBJ.
    receiver_normal = np.zeros_like(origins)
    receiver_normal[hit] = normals[triangle_index[hit], 0]
    receiver_normal[hit] /= np.maximum(
        np.linalg.norm(receiver_normal[hit], axis=1, keepdims=True), 1e-12
    )

    hit_position = np.zeros_like(origins)
    hit_position[hit] = origins[hit] + directions[hit] * distance[hit, None]
    shadow_origin = hit_position + receiver_normal * 1e-3

    light = scene["lights"][0]
    visibility = np.ones(origins.shape[0], dtype=np.float64)
    ndotl = np.zeros(origins.shape[0], dtype=np.float64)
    rng = np.random.default_rng(seed)

    if light["kind"] == "directional":
        to_light = -light["direction"]
        ndotl[hit] = np.maximum(receiver_normal[hit] @ to_light, 0.0)
        occluded = any_occlusion(shadow_origin[hit], np.broadcast_to(to_light, (hit.sum(), 3)),
                                 positions)
        visibility[hit] = np.where(occluded, 0.0, 1.0)
        sample_count = 1
    else:
        corners = light["corners"]
        normal = normalize(np.cross(corners[1] - corners[0], corners[2] - corners[0]))
        samples = area_light_samples(corners, spp, rng)
        sample_count = spp
        visible_sum = np.zeros(hit.sum(), dtype=np.float64)
        receiver_positions = hit_position[hit]
        receiver_normals = receiver_normal[hit]
        for sample in samples:
            to_light = sample[None, :] - receiver_positions
            distance_to_light = np.linalg.norm(to_light, axis=1)
            direction_to_light = to_light / np.maximum(distance_to_light[:, None], 1e-12)
            # The emitter is one sided: the receiver must be on its normal side.
            front = (receiver_positions - sample[None, :]) @ normal > 0.0
            occluded = any_occlusion(shadow_origin[hit], direction_to_light, positions,
                                     max_t=np.maximum(distance_to_light - 1e-3, 0.0))
            visible_sum += np.where(front & ~occluded, 1.0, 0.0)
        visibility[hit] = visible_sum / sample_count
        # Use the centre of the emitter for the receiver's lighting term; the
        # visibility is what this reference is for.
        centre = corners.mean(axis=0)
        to_light = centre[None, :] - receiver_positions
        to_light /= np.maximum(np.linalg.norm(to_light, axis=1, keepdims=True), 1e-12)
        ndotl[hit] = np.maximum(np.einsum("ij,ij->i", receiver_normals, to_light), 0.0)

    image = np.zeros((height * width, 4), dtype=np.float32)
    image[:, 0] = visibility
    image[:, 1] = hit.astype(np.float32)
    image[:, 2] = np.clip(ndotl, 0.0, 1.0)
    image[:, 3] = 1.0
    image = image.reshape(height, width, 4)

    stats = {
        "coverage": float(hit.mean()),
        "visibility_mean": float(visibility[hit].mean()) if hit.any() else 0.0,
        "shadowed_fraction": float((visibility[hit] < 0.5).mean()) if hit.any() else 0.0,
        "samples": sample_count,
        "triangles": int(positions.shape[0]),
    }
    return image, stats


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Trace an independent visibility reference from a .nxscene.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--scene", required=True, type=Path, help="exported .nxscene")
    parser.add_argument("--out", type=Path, help="output EXR (default references/_smoke/<stem>_mask.exr)")
    parser.add_argument("--spp", type=int, default=64,
                        help="area light samples per pixel (directional uses 1)")
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--width", type=int, default=0)
    parser.add_argument("--height", type=int, default=0)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    prepare_environment()

    try:
        scene = parse_nxscene(args.scene)
    except (OSError, SceneError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    width = args.width if args.width > 0 else scene["film"][0]
    height = args.height if args.height > 0 else scene["film"][1]
    if (width, height) != scene["film"]:
        # Keep pixels square while the horizontal fov stays fixed, exactly like
        # the realtime renderer's --width/--height override.
        camera = scene["camera"]
        camera["fov_y"] = math.degrees(
            2.0 * math.atan(math.tan(math.radians(camera["fov_x"]) * 0.5) * height / width)
        )
        print(f"warning: overriding the film to {width}x{height}", file=sys.stderr)

    out_path = args.out if args.out else (
        REPO_ROOT / "references" / "_smoke" / f"{args.scene.stem}_mask.exr"
    )

    print(f"scene     : {args.scene}")
    print(f"resolution: {width}x{height}")
    print(f"light     : {scene['lights'][0]['kind']}")
    print(f"triangles : {sum(mesh['positions'].shape[0] for mesh in scene['meshes'])}")

    start = time.perf_counter()
    image, stats = build_reference(scene, width, height, args.spp, args.seed)
    elapsed = time.perf_counter() - start

    write_exr(out_path, image)
    print("")
    print(f"coverage  : {stats['coverage']:.4f}")
    print(f"visibility: mean={stats['visibility_mean']:.5f} "
          f"shadowed={stats['shadowed_fraction']:.5f}")
    print(f"samples   : {stats['samples']}")
    print(f"time      : {elapsed:.2f} s")
    print(f"output    : {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
