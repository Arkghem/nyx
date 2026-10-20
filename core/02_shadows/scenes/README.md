# 02_shadows scenes

The Mitsuba XML in this directory is the single source of truth for geometry,
camera and lights. The realtime renderer never authors its own scene: it reads
the `.nxscene` export produced by `scripts/export_scene.py`, and the Mitsuba
reference is rendered from the same XML.

## Current scenes

| Scene | Purpose |
|---|---|
| `shadow_basic.xml` | First hard-shadow scene: a 12x12 ground plane, four blockers sitting on it, one directional light. Used for calibration and the P1 SM/PCF measurements. |

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

## Two traps baked into the format

1. **Mitsuba applies `<transform>` children in the order listed.** Write
   `<scale>` first, then `<translate>`. The other order scales the translation
   too and silently moves every blocker toward the origin.
2. **A `.nxscene` `tri` line stores three positions, then three normals.** It is
   not interleaved per vertex. The C++ parser and the Python ray caster both
   assume this layout.

## Workflow

```bash
source env.sh

# Export every scene plus the albedo-AOV copy used for calibration.
python3 scripts/export_scene.py --all --emit-aov

# Radiance reference (linear HDR, the standard answer).
python3 scripts/render_ref.py --scene core/02_shadows/scenes/shadow_basic.xml \
    --spp 64 --seed 0 --out references/_smoke/shadow_basic_direct.exr

# Albedo AOV for camera/geometry calibration.
python3 scripts/render_ref.py --scene .cache/scenes/shadow_basic_albedo.xml \
    --spp 1 --out references/_smoke/shadow_basic_albedo.exr

# Exact hard-shadow visibility, independent of the GPU.
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
