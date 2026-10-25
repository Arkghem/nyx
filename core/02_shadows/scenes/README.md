# 02_shadows scenes

The Mitsuba XML in this directory is the single source of truth for geometry,
camera and lights. The realtime renderer never authors its own scene: it reads
the `.nxscene` export produced by `scripts/export_scene.py`, and the Mitsuba
reference is rendered from the same XML.

## Current scenes

| Scene | Purpose |
|---|---|
| `shadow_basic.xml` | First hard-shadow scene: a 12x12 ground plane, four blockers sitting on it, one directional light. Used for calibration and the P1 SM/PCF measurements. |
| `bistro_plaza.xml` | Bistro Exterior, eye level in the plaza: facade, tree, lamp post. Sun az 55°, el 35°. |
| `bistro_street.xml` | Bistro Exterior, down the street. Sun az 55°, el 35°. |
| `bistro_overview.xml` | Bistro Exterior, elevated oblique overview. Sun az 55°, el 35°. |
| `bistro_plaza_lowsun.xml` | Same plaza camera with a 25° sun; longer shadows, same framing. |

## Bistro Exterior

The four `bistro_*.xml` files are tracked, but their geometry lives outside the
repository in `.cache/assets/bistro/exterior.obj` (generated from the G3D
download). Prepare everything once with:

```bash
source env.sh
python3 core/02_shadows/tools/bistro_scene.py all
```

The tool downloads and verifies `Exterior.zip`, fixes the one invalid vertex
normal that Mitsuba rejects, writes these XMLs, and exports the binary scenes.
Use `--force` on `scenes` only if you want to regenerate the XMLs from the
tool's view table; otherwise edit the tracked XML directly.

The source OBJ is in centimetres; every Bistro XML applies
`<scale value="0.01"/>`. The G3D archive has no textures, so the XML uses one
constant diffuse reflectance and both renderers shade the same BSDF. Do not add
`mtllib` back to the cleaned OBJ: the 132 referenced textures are absent.

Export and render:

```bash
python3 scripts/export_scene.py --binary \
    --scene core/02_shadows/scenes/bistro_plaza.xml

./scripts/run.sh --scene .cache/scenes/bistro_plaza.nxscene --variant sm \
    --cull none --bias 0.001
```

`--binary` is required for Bistro: an inline `nxscene 1` would be hundreds of
megabytes of text. The `.nxscene` is version 2 and points at a content-addressed
`.nxmesh`; four camera variants share one 100 MiB sidecar.

`--cull none --bias 0.001` is the calibrated choice for this asset. The renderer
default (`front`) is tuned for `shadow_basic`'s closed blockers and leaks light
through Bistro's open leaf cards and awnings. See
[../notes/03_bistro.md](../notes/03_bistro.md) for the measurements.

## Scene vocabulary

The exporter accepts a deliberately small subset:

* mesh shapes: `rectangle`, `cube`, `obj`;
* a constant-albedo `diffuse` BSDF (`<rgb name="reflectance" .../>`);
* one `perspective` sensor with a box reconstruction filter;
* `directional` emitters and rectangular `area` emitters;
* `direct` / `aov` / `path` integrators (the renderer ignores the integrator).

It rejects analytic shapes (`sphere`), textured or non-diffuse BSDFs, constant
emitters, multiple sensors, cropped films and principal-point offsets. A
tessellated OBJ is the way to get a curved mesh: both renderers then consume the
same triangles, while an analytic sphere's silhouette would not match a
tessellation.

## Three traps baked into the format

1. **Mitsuba applies `<transform>` children in the order listed.** Write
   `<scale>` first, then `<translate>`. The other order scales the translation
   too and silently moves every blocker toward the origin.
2. **A `.nxscene` `tri` line stores three positions, then three normals.** It is
   not interleaved per vertex. The C++ parser and the Python ray caster both
   assume this layout.
3. **A `.nxscene` v2 `meshfile` path is relative to the `.nxscene` file**, and
   the sidecar name is a content digest, not a scene name. Four camera variants
   therefore share one mesh; editing or re-preparing the OBJ produces a new
   sidecar instead of silently reusing a stale one.

## Workflow

```bash
source env.sh

# Small scenes: inline triangles + the albedo-AOV copy used for calibration.
python3 scripts/export_scene.py --all --emit-aov

# Bistro: binary sidecars; one shared mesh for all four camera presets.
python3 core/02_shadows/tools/bistro_scene.py export

# Radiance reference (linear HDR, the standard answer).
python3 scripts/render_ref.py --scene core/02_shadows/scenes/shadow_basic.xml \
    --spp 64 --seed 0 --out references/_smoke/shadow_basic_direct.exr

# Albedo AOV for camera/geometry calibration.
python3 scripts/render_ref.py --scene .cache/scenes/shadow_basic_albedo.xml \
    --spp 1 --out references/_smoke/shadow_basic_albedo.exr

# Exact hard-shadow visibility, independent of the GPU.
# (Inline-triangle scenes only; Bistro is rejected on purpose.)
python3 core/02_shadows/tools/raycast_ref.py \
    --scene .cache/scenes/shadow_basic.nxscene \
    --out references/_smoke/shadow_basic_mask.exr

# Realtime render from the export.
./scripts/run.sh --variant sm
```

The exporter writes to `.cache/scenes/` (gitignored). The renderer warns when the
source XML is newer than the export; rerun the exporter after editing a scene.

Resolution and camera live in the XML. `--width/--height` on the renderer
overrides them and recomputes the vertical field of view, which is useful for
performance runs; a quality comparison against Mitsuba must use the same aspect.
The ray-cast tool takes the same override for mask comparisons.

## Adding a scene

1. Copy `shadow_basic.xml` and change the geometry/lights. Keep the vocabulary
   above; the exporter fails loudly rather than approximating.
2. Put the light outside the camera frustum for radiance comparisons: the
   realtime shader does not draw emitter geometry, so a visible light would only
   appear in the Mitsuba reference.
3. Export it, render the reference, and calibrate with the albedo AOV before
   trusting any shadow number. The procedure and the traps are in
   [../notes/01_shadow_map_conventions.md](../notes/01_shadow_map_conventions.md).
4. For a mesh over 200k triangles use `scripts/export_scene.py --binary` (or the
   Bistro tool). The exporter refuses to inline a large mesh into the text
   format, because the result would be hundreds of megabytes and minutes of
   parsing.
