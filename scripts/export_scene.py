#!/usr/bin/env python3
"""Export a Mitsuba scene to the flat `.nxscene` format used by native experiments.

Why this exists
---------------
nyx's rule is that the Mitsuba XML is the single source of truth for geometry,
camera and lights. The native Metal renderer must therefore never author its own
scene: it reads an export produced by this script, so both sides see the same
world-space triangles.

The format is deliberately line oriented instead of JSON or a binary blob. A
scene is a few thousand triangles at most, the file is easy to grep, and the C++
reader is a few dozen lines with a precise error message per line.

Coordinate and unit conventions
-------------------------------
* World space, right-handed, Y up, linear RGB, the same units as Mitsuba.
* Vertices are baked into world space: `vertex_position()` already applies the
  shape's `to_world`.
* The camera is described by a basis (`right`, `up`, `forward`) derived from
  `sensor.sample_ray()`. The sensor's `to_world` matrix is *not* usable as an
  OpenGL view matrix: its local axes are not the film's left/right/forward
  axes. Sampling rays is convention-free and survives any sensor transform.
* Triangle winding is copied from Mitsuba. The Metal pipeline must be told
  explicitly which winding is front facing; that is calibrated in 02_shadows.

Supported vocabulary
--------------------
Mesh shapes (`rectangle`, `cube`, `obj`), a constant-albedo `diffuse` BSDF,
one perspective sensor with a box reconstruction filter, directional emitters
and rectangular area emitters. Anything else is rejected with an explanation
instead of being silently approximated.

Usage
-----
    python3 scripts/export_scene.py --all
    python3 scripts/export_scene.py --scene core/02_shadows/scenes/shadow_basic.xml
    python3 scripts/export_scene.py --all --emit-aov

Outputs land in `.cache/scenes/` (gitignored). The renderer prints the exact
command to run when the export is missing.
"""

from __future__ import annotations

import argparse
import glob
import math
import os
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

import numpy as np

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUT_DIR = REPO_ROOT / ".cache" / "scenes"
DEFAULT_VARIANT = os.environ.get("MI_DEFAULT_VARIANT", "metal_ad_rgb")
DEFAULT_SCENE_GLOB = "core/02_shadows/scenes/*.xml"

EXPORT_VERSION = 1


class ExportError(RuntimeError):
    """A scene uses something the native side cannot represent."""


# ---------------------------------------------------------------------------
# Mitsuba environment
# ---------------------------------------------------------------------------


def prepare_environment() -> None:
    """Keep drjit's caches inside the repository.

    drjit writes a JIT cache on first import. Its default location is ~/.drjit,
    which this machine's file sandbox refuses, costing a full recompile on every
    run. The same two settings as scripts/render_ref.py.
    """
    os.environ.setdefault("DRJIT_CACHE_DIR", str(REPO_ROOT / ".cache" / "drjit"))
    if "DRJIT_LIBLLVM_PATH" not in os.environ:
        candidates = sorted(glob.glob("/opt/homebrew/opt/llvm*/lib/libLLVM.dylib"))
        if candidates:
            os.environ["DRJIT_LIBLLVM_PATH"] = candidates[-1]


def import_mitsuba(variant: str):
    try:
        import mitsuba as mi
    except ImportError as exc:  # noqa: BLE001 - the message is the useful part
        raise ExportError(f"cannot import mitsuba ({exc})") from exc

    try:
        mi.set_variant(variant)
    except Exception as exc:  # noqa: BLE001
        hint = ""
        if variant.startswith("llvm"):
            hint = " (llvm variants need DRJIT_LIBLLVM_PATH; see env.sh)"
        raise ExportError(f"cannot activate variant '{variant}': {exc}{hint}") from exc
    return mi


# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------


def fnum(value: float) -> str:
    """Format a float compactly without losing meaningful precision."""
    return f"{float(value):.9g}"


def as_array(value) -> np.ndarray:
    return np.asarray(value, dtype=np.float64)


def as_vec3(value, what: str) -> np.ndarray:
    array = as_array(value).reshape(-1)
    if array.size < 3:
        raise ExportError(f"{what}: expected at least 3 components, got {array.size}")
    return array[:3].astype(np.float64)


def normalize(vector: np.ndarray, what: str) -> np.ndarray:
    length = float(np.linalg.norm(vector))
    if not math.isfinite(length) or length < 1e-12:
        raise ExportError(f"{what}: degenerate vector {vector}")
    return vector / length


def vec_line(values) -> str:
    return " ".join(fnum(v) for v in values)


def scalar_property(params, key: str, default: float | None = None) -> float:
    if key not in params:
        if default is None:
            raise ExportError(f"missing scalar property '{key}'")
        return default
    return float(as_array(params[key]).reshape(-1)[0])


# ---------------------------------------------------------------------------
# Camera
# ---------------------------------------------------------------------------


def camera_from_sensor(mi, sensor) -> dict:
    if sensor.class_name() != "PerspectiveCamera":
        raise ExportError(
            f"unsupported sensor '{sensor.class_name()}': only PerspectiveCamera is supported"
        )

    params = mi.traverse(sensor)
    film = sensor.film()
    size = tuple(int(x) for x in film.size())
    crop = tuple(int(x) for x in film.crop_size())
    offset = tuple(int(x) for x in film.crop_offset())
    if crop != size or offset != (0, 0):
        raise ExportError(
            f"film crop/offset is not supported: size={size} crop={crop} offset={offset}"
        )
    if film.rfilter().class_name() != "BoxFilter":
        print(
            f"warning: {sensor} uses a {film.rfilter().class_name()}; "
            "references should use a box filter so geometry edges mean the same thing",
            file=sys.stderr,
        )

    near = scalar_property(params, "near_clip")
    far = scalar_property(params, "far_clip")
    if not (0.0 < near < far):
        raise ExportError(f"invalid near/far clip: near={near} far={far}")

    # The traversed x_fov is already in degrees (the XML's `fov` unit).
    x_fov = scalar_property(params, "x_fov", 0.0)
    if x_fov <= 0.0:
        # Some sensors carry fov only as an axis; fall back to a ray-derived
        # estimate below instead of failing here.
        x_fov = float("nan")

    # The sensor's local frame is not the film frame, so derive the basis from
    # rays. sample_ray() returns rays whose origin is on the near plane; the
    # direction is what matters, and the origin comes from to_world.
    def direction(uv: tuple[float, float]) -> np.ndarray:
        ray, _weight = sensor.sample_ray(0.0, 0.5, mi.Point2f(*uv), mi.Point2f(0.5, 0.5))
        return normalize(as_vec3(ray.d, f"camera ray at {uv}"), f"camera ray at {uv}")

    forward = direction((0.5, 0.5))
    right = direction((1.0, 0.5))
    right = normalize(right - float(np.dot(right, forward)) * forward, "camera right")
    up = direction((0.5, 0.0))
    up = normalize(
        up - float(np.dot(up, forward)) * forward - float(np.dot(up, right)) * right,
        "camera up",
    )

    # Right-handed camera with forward = -Z: right x up must equal -forward.
    if float(np.dot(np.cross(right, up), -forward)) < 0.999:
        raise ExportError("camera basis is not right-handed; the sensor is not a pinhole camera")
    if abs(float(np.dot(right, up))) > 1e-3:
        raise ExportError("camera basis is not orthogonal")

    matrix = as_array(params["to_world"].matrix).reshape(4, 4)
    origin = matrix[:3, 3].copy()

    if not math.isfinite(x_fov):
        half = math.acos(max(-1.0, min(1.0, float(np.dot(forward, direction((1.0, 0.5)))))))
        x_fov = math.degrees(2.0 * half)
    else:
        half_ray = math.degrees(
            math.acos(max(-1.0, min(1.0, float(np.dot(forward, direction((1.0, 0.5)))))))
        )
        if abs(half_ray - x_fov * 0.5) > 1.0:
            print(
                f"warning: x_fov={x_fov:.3f} deg but the edge ray implies "
                f"{2.0 * half_ray:.3f} deg; using x_fov for the projection",
                file=sys.stderr,
            )

    aspect = size[1] / size[0]
    y_fov = math.degrees(2.0 * math.atan(math.tan(math.radians(x_fov) * 0.5) * aspect))

    return {
        "origin": origin,
        "right": right,
        "up": up,
        "forward": forward,
        "x_fov": x_fov,
        "y_fov": y_fov,
        "near": near,
        "far": far,
        "width": size[0],
        "height": size[1],
    }


# ---------------------------------------------------------------------------
# Materials and geometry
# ---------------------------------------------------------------------------


def diffuse_albedo(shape) -> np.ndarray:
    bsdf = shape.bsdf()
    name = bsdf.class_name()
    if name not in ("SmoothDiffuse", "Diffuse"):
        raise ExportError(
            f"shape '{shape.id()}' uses BSDF '{name}'; only a constant-albedo diffuse "
            "BSDF is supported (texture and microfacet materials would not compare)"
        )

    params = mi_traverse_safe(bsdf)
    if "reflectance.value" not in params:
        raise ExportError(
            f"shape '{shape.id()}' has a non-constant diffuse reflectance "
            "(a texture?); use a constant RGB reflectance for shadow experiments"
        )
    albedo = as_vec3(params["reflectance.value"], f"albedo of '{shape.id()}'")
    if np.any(albedo < 0.0) or np.any(albedo > 1.0):
        raise ExportError(f"shape '{shape.id()}' albedo {albedo} is outside [0, 1]")
    return albedo


def mesh_triangles(shape) -> list[tuple[np.ndarray, np.ndarray]]:
    if not shape.is_mesh():
        raise ExportError(
            f"shape '{shape.id()}' ({shape.class_name()}) is an analytic shape, not a mesh. "
            "Use rectangle/cube/obj; a tessellated OBJ keeps both renderers on the same "
            "triangles (a sphere's analytic silhouette would not match a tessellation)."
        )

    vertex_count = int(shape.vertex_count())
    face_count = int(shape.face_count())
    if vertex_count == 0 or face_count == 0:
        raise ExportError(f"shape '{shape.id()}' has no triangles")

    positions = [
        as_vec3(shape.vertex_position(i), f"vertex {i} of '{shape.id()}'")
        for i in range(vertex_count)
    ]
    has_normals = bool(shape.has_vertex_normals())
    normals = (
        [
            normalize(
                as_vec3(shape.vertex_normal(i), f"normal {i} of '{shape.id()}'"),
                f"normal {i} of '{shape.id()}'",
            )
            for i in range(vertex_count)
        ]
        if has_normals
        else []
    )

    triangles: list[tuple[np.ndarray, np.ndarray]] = []
    for face in range(face_count):
        indices = [int(x) for x in as_array(shape.face_indices(face)).reshape(-1)]
        if len(indices) != 3:
            raise ExportError(
                f"shape '{shape.id()}' has a face with {len(indices)} vertices; "
                "the renderer only draws triangles"
            )
        p = [positions[i] for i in indices]
        if has_normals:
            n = [normals[i] for i in indices]
        else:
            face_normal = normalize(np.cross(p[1] - p[0], p[2] - p[0]), "face normal")
            n = [face_normal, face_normal, face_normal]
        triangles.append((np.stack(p), np.stack(n)))

    return triangles


# ---------------------------------------------------------------------------
# Lights
# ---------------------------------------------------------------------------


def _orient_quad(points: np.ndarray, normal: np.ndarray) -> np.ndarray:
    """Sort four coplanar points around their centroid and face `normal`."""
    if points.shape != (4, 3):
        raise ExportError(f"area light needs exactly 4 corners, got {points.shape[0]}")

    center = points.mean(axis=0)
    u = normalize(points[0] - center, "area light edge")
    u = normalize(u - float(np.dot(u, normal)) * normal, "area light in-plane axis")
    v = normalize(np.cross(normal, u), "area light in-plane axis")

    angles = [math.atan2(float(np.dot(p - center, v)), float(np.dot(p - center, u))) for p in points]
    order = np.argsort(np.asarray(angles))
    sorted_points = points[order]

    polygon_normal = normalize(
        np.cross(sorted_points[1] - sorted_points[0], sorted_points[2] - sorted_points[0]),
        "area light polygon normal",
    )
    if float(np.dot(polygon_normal, normal)) < 0.0:
        sorted_points = sorted_points[::-1]
    return sorted_points


def area_light_from_shape(shape) -> tuple[np.ndarray, np.ndarray]:
    emitter = shape.emitter()
    if emitter is None or emitter.class_name() != "AreaLight":
        raise ExportError(f"shape '{shape.id()}' has an unsupported emitter")

    if int(shape.vertex_count()) != 4:
        raise ExportError(
            f"area emitter '{shape.id()}' must be a rectangle (4 vertices), "
            f"got {shape.vertex_count()}"
        )

    points = np.stack(
        [as_vec3(shape.vertex_position(i), f"light corner {i}") for i in range(4)]
    )
    if shape.has_vertex_normals():
        normal = normalize(as_vec3(shape.vertex_normal(0), "light normal"), "light normal")
    else:
        normal = normalize(
            np.cross(points[1] - points[0], points[2] - points[0]), "light normal"
        )

    radiance = as_vec3(
        mi_traverse_safe(emitter)["radiance.value"], f"radiance of '{shape.id()}'"
    )
    return _orient_quad(points, normal), radiance


def directional_light_from_emitter(mi, emitter) -> tuple[np.ndarray, np.ndarray]:
    params = mi_traverse_safe(emitter)
    matrix = as_array(params["to_world"].matrix).reshape(4, 4)
    # The emitter's local +Z is the propagation direction (verified against a
    # known plane: direction (0,0,-1) lights a plane whose normal is +Z).
    direction = normalize(matrix[:3, 2], "directional light direction")
    irradiance = as_vec3(params["irradiance.value"], "directional irradiance")
    return direction, irradiance


# ---------------------------------------------------------------------------
# Scene traversal
# ---------------------------------------------------------------------------


def mi_traverse_safe(obj):
    """`mi.traverse()` wrapper with a readable error."""
    import mitsuba as mi

    try:
        return mi.traverse(obj)
    except Exception as exc:  # noqa: BLE001
        raise ExportError(f"cannot traverse {obj}: {exc}") from exc


def collect_scene(mi, scene, source: Path) -> dict:
    sensors = scene.sensors()
    if len(sensors) != 1:
        raise ExportError(f"expected exactly one sensor, found {len(sensors)}")
    camera = camera_from_sensor(mi, sensors[0])

    meshes = []
    lights = []

    for shape in scene.shapes():
        if shape.is_emitter():
            points, radiance = area_light_from_shape(shape)
            lights.append({"kind": "area", "radiance": radiance, "corners": points})
            continue
        albedo = diffuse_albedo(shape)
        triangles = mesh_triangles(shape)
        meshes.append({"albedo": albedo, "triangles": triangles})

    for emitter in scene.emitters():
        name = emitter.class_name()
        if name == "AreaLight":
            # Already represented through its parent shape.
            continue
        if name == "DirectionalEmitter":
            direction, irradiance = directional_light_from_emitter(mi, emitter)
            lights.append(
                {"kind": "directional", "direction": direction, "irradiance": irradiance}
            )
            continue
        if name == "ConstantEmitter":
            raise ExportError(
                "constant emitters are not supported yet; they would add an ambient term "
                "that the realtime shading pass does not model. Remove it for shadow "
                "comparisons, or add an explicit ambient model first."
            )
        raise ExportError(f"unsupported emitter '{name}'")

    if not meshes:
        raise ExportError("scene has no mesh geometry")
    if not lights:
        raise ExportError("scene has no lights")
    if len(lights) > 1:
        print(
            f"warning: {source.name} has {len(lights)} lights; the renderer currently uses "
            "the first one as the shadow-casting light",
            file=sys.stderr,
        )

    return {
        "camera": camera,
        "meshes": meshes,
        "lights": lights,
        "integrator": scene.integrator().class_name(),
    }


# ---------------------------------------------------------------------------
# Writing
# ---------------------------------------------------------------------------


def write_nxscene(scene: dict, source: Path, target: Path, variant: str) -> None:
    camera = scene["camera"]
    lines: list[str] = []
    lines.append("# nyx .nxscene, exported from Mitsuba")
    lines.append(f"# source: {source.resolve()}")
    try:
        lines.append(f"# source_mtime: {int(source.stat().st_mtime)}")
    except OSError:
        pass
    lines.append(f"# mitsuba: {variant}")
    lines.append(f"nxscene {EXPORT_VERSION}")
    lines.append(f"film {camera['width']} {camera['height']}")
    lines.append(
        "camera "
        + vec_line(camera["origin"])
        + " "
        + vec_line(camera["right"])
        + " "
        + vec_line(camera["up"])
        + " "
        + vec_line(camera["forward"])
        + " "
        + vec_line(
            [
                camera["x_fov"],
                camera["y_fov"],
                camera["near"],
                camera["far"],
            ]
        )
    )

    for light in scene["lights"]:
        if light["kind"] == "directional":
            lines.append(
                "light directional "
                + vec_line(light["direction"])
                + " "
                + vec_line(light["irradiance"])
            )
        else:
            lines.append(
                "light area "
                + vec_line(light["radiance"])
                + " "
                + vec_line(light["corners"].reshape(-1))
            )

    for mesh in scene["meshes"]:
        triangles = mesh["triangles"]
        lines.append(
            "mesh " + vec_line(mesh["albedo"]) + " " + str(len(triangles))
        )
        for positions, normals in triangles:
            lines.append(
                "tri "
                + vec_line(positions.reshape(-1))
                + " "
                + vec_line(normals.reshape(-1))
            )

    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_aov_xml(source: Path, target: Path) -> None:
    """Write a copy of `source` whose integrator renders the albedo AOV.

    The geometry, camera and lights are untouched, so the calibration image is
    produced from exactly the same scene description.
    """
    tree = ET.parse(source)
    root = tree.getroot()
    if root.tag != "scene":
        raise ExportError(f"{source} has root tag '{root.tag}', expected 'scene'")

    for child in list(root):
        if child.tag == "integrator":
            root.remove(child)

    integrator = ET.SubElement(root, "integrator", {"type": "aov"})
    ET.SubElement(integrator, "string", {"name": "aovs", "value": "albedo:albedo"})

    target.parent.mkdir(parents=True, exist_ok=True)
    tree.write(target, encoding="utf-8", xml_declaration=True)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Export Mitsuba scenes to .nxscene for the native renderer.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--scene", action="append", type=Path, default=[],
                        help="scene XML to export (repeatable)")
    parser.add_argument("--all", action="store_true",
                        help=f"export every scene matching {DEFAULT_SCENE_GLOB}")
    parser.add_argument("--out-dir", type=Path, default=DEFAULT_OUT_DIR,
                        help=f"output directory (default {DEFAULT_OUT_DIR})")
    parser.add_argument("--emit-aov", action="store_true",
                        help="also write <scene>_albedo.xml with an albedo AOV integrator")
    parser.add_argument("--variant", default=DEFAULT_VARIANT,
                        help=f"Mitsuba variant (default {DEFAULT_VARIANT})")
    parser.add_argument("--check", action="store_true",
                        help="load and validate without writing anything")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    prepare_environment()
    try:
        mi = import_mitsuba(args.variant)
    except ExportError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    scenes = list(args.scene)
    if args.all:
        scenes.extend(sorted(Path(REPO_ROOT).glob(DEFAULT_SCENE_GLOB)))
    scenes = [path if path.is_absolute() else (Path(REPO_ROOT) / path) for path in scenes]
    # De-duplicate while preserving order.
    seen: set[Path] = set()
    unique = []
    for path in scenes:
        resolved = path.resolve()
        if resolved not in seen:
            seen.add(resolved)
            unique.append(path)
    scenes = unique

    if not scenes:
        print("error: pass --scene <xml> or --all", file=sys.stderr)
        return 2

    print(f"variant: {mi.variant()} (mitsuba {mi.__version__})")
    print(f"output : {args.out_dir}")
    print("")

    failures = 0
    for source in scenes:
        label = source.name
        try:
            if not source.exists():
                raise ExportError(f"no scene at {source}")
            scene = mi.load_file(str(source))
            data = collect_scene(mi, scene, source)
            triangles = sum(len(mesh["triangles"]) for mesh in data["meshes"])
            summary = (
                f"{len(data['meshes'])} mesh(es), {triangles} triangles, "
                f"{len(data['lights'])} light(s), integrator={data['integrator']}, "
                f"film={data['camera']['width']}x{data['camera']['height']}"
            )
            if args.check:
                print(f"  [ok  ] {label}: {summary}")
                continue

            stem = source.stem
            target = args.out_dir / f"{stem}.nxscene"
            write_nxscene(data, source, target, mi.variant())
            wrote = [target]
            if args.emit_aov:
                aov_target = args.out_dir / f"{stem}_albedo.xml"
                write_aov_xml(source, aov_target)
                wrote.append(aov_target)
            print(f"  [ok  ] {label}: {summary}")
            for path in wrote:
                print(f"         -> {path}")
        except ExportError as exc:
            failures += 1
            print(f"  [FAIL] {label}: {exc}", file=sys.stderr)
        except Exception as exc:  # noqa: BLE001 - surface the parser message
            failures += 1
            print(f"  [FAIL] {label}: {type(exc).__name__}: {exc}", file=sys.stderr)

    print("")
    if failures:
        print(f"{failures} scene(s) failed", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
