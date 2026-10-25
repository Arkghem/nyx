# 02_shadows — realtime shadow lab

A learning lab for shadow algorithms. Every technique is treated as a
**visibility solver**: the same scene, camera, light and shading pass judge it,
so the only thing that changes is how the occlusion term is estimated.

The standard answer comes from Mitsuba, but **only offline**. Mitsuba is not in
the realtime loop: it produces one radiance reference per scene and exports the
world-space triangles. Every algorithm and every performance number runs in the
native Metal renderer in this directory.

## Offline truth vs realtime cost

| stage | tool | frequency | inside the frame? | output |
|---|---|---|---|---|
| radiance reference | Mitsuba `direct` | once per scene | no | `references/*.exr` |
| scene export | `scripts/export_scene.py` | when the XML changes | no | `.cache/scenes/*.nxscene` |
| visibility reference | `tools/raycast_ref.py` | once per scene | no | `references/_smoke/*_mask.exr` |
| algorithm | native Metal | every frame | **yes** | visibility / radiance |
| cost | GPU command-buffer time + CPU timer | every frame (bench) | **yes** | `reports/bench/*.json` |
| quality | `scripts/compare.py`, `tools/shadow_metrics.py` | after rendering | no | `reports/quality/*.json` |

The native renderer is a realtime loop on the same GPU, but it is not a game
engine: culling, material binding and RenderGraph overhead are absent. Its
milliseconds are **algorithm-level cost**, not a game frame rate. The report and
the notes say so explicitly.

## Status

P0, P1 and the Bistro large-scene scaffold are implemented:

* hard shadow map (`sm`), percentage-closer filtering (`pcf` with 3/5 taps);
* calibration variants (`albedo`, `lit`, `depth`) and a camera/projection
  self-test;
* Mitsuba AOV/albedo calibration and an independent ray-cast visibility
  reference;
* a quality/cost Pareto over shadow-map size and filter taps;
* a binary `.nxmesh` import path and four camera/light presets for the
  2.84M-triangle Amazon Lumberyard Bistro Exterior.

Later phases add PCSS, VSM/EVSM/MSM, CSM, PSM, shadow volumes, virtual shadow
maps, voxel shadows and AVSM. The notes in `notes/` are the reading path and the
record of what was measured.

## Quick start

```bash
source env.sh
python3 scripts/export_scene.py --all
./scripts/build.sh --release 02_shadows

# one image + its visibility mask
./scripts/run.sh --variant sm

# 1080p, 2048 shadow map, PCF 5x5
./scripts/run.sh --variant pcf5 --width 1920 --height 1080 --shadow-size 2048

# explicit composition (the same thing without a preset)
./scripts/run.sh --pipeline partition=single_ortho,storage=depth,filter=pcf:5,bias=slope

# camera/projection and frame sanity checks
./scripts/run.sh --self-test
```

The default scene is `.cache/scenes/shadow_basic.nxscene`; if it is missing the
renderer prints the exporter command. `--list-variants` and `--list-pipelines`
describe what the current build knows.

The renderer writes a linear radiance EXR and a one-channel visibility EXR. The
default names encode the pipeline, resolution, shadow-map size, bias and seed,
so two runs that should match have identical names.

## Bistro Exterior (large-scene scaffold)

The second scene is the Amazon Lumberyard Bistro Exterior
([CC-BY 4.0](https://developer.nvidia.com/orca/amazon-lumberyard-bistro),
2,837,209 triangles in the G3D OBJ). It is not checked in. One command downloads
it, verifies the zip, fixes the asset, writes the camera XMLs and exports the
binary scenes:

```bash
source env.sh
python3 core/02_shadows/tools/bistro_scene.py all
```

| step | output |
|---|---|
| `fetch` | `third_party/_deps/bistro/Exterior/exterior.obj` (297 MiB) |
| `prepare` | `.cache/assets/bistro/exterior.obj` + `manifest.json` |
| `scenes` | the tracked `scenes/bistro_*.xml` camera presets |
| `export` | `.cache/scenes/bistro_*.nxscene` + one shared 100 MiB `.nxmesh` |

The zip is 61 MiB (64.2 MB) and pinned by SHA-256
`f612ba0d8a65811afe0d48a023d31e5b43ac40b78e9b12d15e2b7dc8923c29d4`. The G3D
archive contains only `exterior.obj` and `exterior.mtl`: there are **no
textures**, and one zero-length vertex normal makes Mitsuba reject the whole
mesh. `prepare` replaces that normal with the previous valid one and drops the
132 missing-texture material references. Both renderers then shade the same
geometry with a constant clay albedo `(0.62, 0.60, 0.56)`, which is the right
call for a shadow lab: a metric must not depend on texture filtering. The OBJ is
in centimetres; every XML applies `<scale value="0.01"/>`, so cameras, clip
planes and biases are in metres. The missing textures also mean that foliage
cards are opaque: canopy shadows are solid blobs, so judge shadow edges on the
facades and street, not on the trees.

| scene | camera | sun | purpose |
|---|---|---|---|
| `bistro_plaza` | eye level, plaza facade | az 55°, el 35° | tree/lamp/facade shadows |
| `bistro_street` | down the street | az 55°, el 35° | long facade, shadow direction |
| `bistro_overview` | elevated oblique | az 55°, el 35° | shadow-map coverage |
| `bistro_plaza_lowsun` | same plaza camera | az 55°, el 25° | longer shadows, same framing |

```bash
# hero view, 1280x720 from the XML
./scripts/run.sh --scene .cache/scenes/bistro_plaza.nxscene --variant sm \
    --cull none --bias 0.001

# the shadow-map Pareto on the same view
./scripts/run.sh --scene .cache/scenes/bistro_plaza.nxscene --variant pcf5 \
    --shadow-size 4096 --cull none --bias 0.001

# the same camera, exact ray-traced reference
python3 scripts/render_ref.py --scene core/02_shadows/scenes/bistro_plaza.xml \
    --spp 64 --seed 0 --out references/_smoke/bistro_plaza_64spp_seed0.exr

# headline cost: batched frames, three runs, best p95
./scripts/bench.sh 02_shadows --tag bistro_plaza_2048 --frames 60 --repeat 3 \
    -- --scene .cache/scenes/bistro_plaza.nxscene --variant sm \
       --cull none --bias 0.001 --shadow-size 2048
```

**Use `--cull none --bias 0.001` for Bistro.** The CLI default (`--cull front`)
is calibrated on the closed blockers in `shadow_basic`; on Bistro's open leaf
cards and awnings it stores the far side of thin geometry and leaks light.
Keeping everything and comparing against the same Mitsuba reference raises PSNR
at 2048² from 14.5 dB (front culling) to 18.3 dB (no culling). That is a property
of the asset, not a bug in the default: the default is right for the small
calibration scene, which is why the Bistro commands are explicit.

The first export writes the 100 MiB sidecar; the other three camera variants
reuse it because the sidecar is content addressed. Loading the whole scene takes
about one second. The CPU ray caster (`tools/raycast_ref.py`) intentionally
refuses `meshfile` scenes: it brute-forces every triangle in numpy and would take
hours at this scale. The Mitsuba direct render is the radiance truth for Bistro.

Measured on the bench machine (Apple M5, 1280x720, 2.84M triangles, `--cull none
--bias 0.001`, 60 frames per run, three runs, best p95):

| shadow map | PSNR | SSIM | MAE | p50 ms | p95 ms | shadow MiB |
|---|---|---|---|---|---|---|
| 2048² | 18.41 dB | 0.825 | 0.0324 | 2.68 | 3.16 | 16 |
| 8192² | 19.24 dB | 0.873 | 0.0276 | 3.45 | 4.00 | 256 |

The quality reference is 64 spp Mitsuba `direct`; the remaining error is the
shadow-map footprint (8.4 cm/texel at 2048², 2.1 cm at 8192²) and the realtime
G-buffer's lack of antialiasing. The 4x resolution costs 0.84 ms of p95 and
240 MiB of shadow memory, which is exactly the kind of Pareto point the lab is
for. These are **algorithm-level** milliseconds from a headless native renderer,
not a game frame.

The metrics use the realtime **albedo** image as the geometry ROI (eroded by
2 px), not `compare.py`'s default silhouette. In a direct-only scene the default
silhouette treats pure-black shadowed pixels as background, so it is not a
geometry mask; using it would report a different, meaningless coverage.

## Scenes

The Mitsuba XML is the single source of truth. `scripts/export_scene.py` loads
it with Mitsuba and writes world-space triangles, the camera basis and the
lights to `.cache/scenes/<name>.nxscene`. The C++ side never models geometry
itself.

Small scenes keep their triangles inline in a text `mesh` block (`nxscene 1`).
Large meshes use `--binary`: the scene becomes `nxscene 2`, and each mesh is a
content-addressed `.nxmesh` sidecar holding an indexed float32 vertex buffer and
uint32 indices. The layout is documented in `src/mesh_format.h`; the renderer
reads it straight into the Metal buffers and never builds a CPU triangle list.
The Bistro camera XMLs in `scenes/` are the tracked files the exporter reads;
they were generated once by `tools/bistro_scene.py` (use `--force` to rewrite
them from its view table).

Supported vocabulary: mesh shapes (`rectangle`, `cube`, `obj`), a constant
albedo `diffuse` BSDF, a perspective camera with a box filter, directional
lights and rectangular area lights. `sphere` is an analytic shape in Mitsuba and
is rejected: a tessellated OBJ keeps both renderers on the same triangles.

Two traps the exporter comments explain: Mitsuba applies `<transform>` children
in the order listed (`<scale>` then `<translate>`), and a `.nxscene` triangle
stores positions first, then normals.

## Calibration before any shadow number

Run the albedo and unshadowed-direct comparisons first. A camera mismatch,
a transposed matrix or a wrong light unit makes every shadow metric meaningless.

```bash
# albedo AOV is generated from the same scene by the exporter
python3 scripts/render_ref.py --scene .cache/scenes/shadow_basic_albedo.xml \
    --spp 1 --out references/_smoke/shadow_basic_albedo.exr
./scripts/run.sh --variant albedo --out outputs/02_shadows/shadow_basic_albedo.exr
python3 scripts/compare.py --reference references/_smoke/shadow_basic_albedo.exr \
    --test outputs/02_shadows/shadow_basic_albedo.exr --mask interior --erode 2

# unshadowed direct lighting: only pixels the ray-cast reference says are lit
python3 scripts/render_ref.py --scene core/02_shadows/scenes/shadow_basic.xml \
    --spp 64 --seed 0 --out references/_smoke/shadow_basic_direct.exr
./scripts/run.sh --variant lit --out outputs/02_shadows/shadow_basic_lit.exr
python3 scripts/compare.py --reference references/_smoke/shadow_basic_direct.exr \
    --test outputs/02_shadows/shadow_basic_lit.exr \
    --roi references/_smoke/shadow_basic_mask.exr --roi-ndotl --roi-erode 2
```

Current calibration numbers on `shadow_basic`: albedo silhouette IoU 0.999324,
albedo MAE 1.33e-4, PSNR 48.09 dB; unshadowed direct lighting matches at float
precision in the bulk (the ROI MAE 3.98e-4 is dominated by antialiased edges).
The albedo maximum error (0.2) sits on the coplanar cube/ground contact: Mitsuba's
AOV samples the cube's bottom face there while the realtime G-buffer culls it. It
is a contact artifact, not a camera or geometry mismatch; away from material
boundaries the albedo error is at float precision.

## Visibility truth

`tools/raycast_ref.py` traces the exact same triangles independently of the GPU.
It writes four channels: visibility, object mask, `max(dot(n, -light), 0)`, and
alpha. The metrics exclude background and back-facing pixels using those
channels.

```bash
python3 core/02_shadows/tools/raycast_ref.py \
    --scene .cache/scenes/shadow_basic.nxscene \
    --out references/_smoke/shadow_basic_mask.exr

python3 core/02_shadows/tools/shadow_metrics.py \
    --reference references/_smoke/shadow_basic_mask.exr \
    --test outputs/02_shadows/shadow_basic_sm_768x768_sm2048_b0.00100_seed0_vis.exr \
    --variant sm --scene shadow_basic --shadow-size 2048 --bias 0.001 \
    --out reports/quality/shadow_basic_sm.json
```

A directional light needs one shadow ray and is exact; an area light averages
`--spp` stratified rays and is much slower. `compare.py` handles PSNR, MAE,
SSIM and difference images; it always works in linear light.

The CPU caster is `O(pixels × triangles)` and deliberately refuses `meshfile`
scenes. At Bistro's 2.84M triangles it would take hours, so Bistro is judged
against the Mitsuba `direct` radiance reference instead of a separate visibility
mask. A GPU/Mitsuba-ray visibility pass is a later addition, not a prerequisite
for the comparison above.

## Realtime benchmark

Use a Release build. `--bench` warns if `NDEBUG` is absent, because a Debug
build's milliseconds are not a measurement.

```bash
./scripts/build.sh --release 02_shadows

# headline: one command buffer for the whole frame, 8 frames batched per
# measurement, best-of-3, p95
./scripts/bench.sh 02_shadows --tag sm --frames 300 --repeat 3 \
    -- --variant sm --width 1920 --height 1080

# per-pass breakdown: one command buffer per pass (an upper bound, documented)
./scripts/bench.sh 02_shadows --tag sm_passes --frames 200 --repeat 1 \
    -- --variant sm --width 1920 --height 1080 --timing passes
```

`--bench-iterations` (default 8) encodes the same frame N times into one command
buffer and divides the GPU time by N. The frame is sub-millisecond at this scene
size; measuring a single frame would be dominated by scheduling noise. The
report records the iteration count in `metadata`.

The benchmark JSON contains GPU p50/p95/p99, CPU encode+commit time, peak
shadow/G-buffer bytes, tap/cascade counts and the pipeline/scene metadata.
`scripts/perf_gate.py` can compare a candidate against a baseline:
`reports/baselines/02_shadows_<tag>.json` (tracked) vs
`reports/bench/02_shadows_<tag>_*.json` (ignored).

Join quality and cost into a Pareto table:

```bash
python3 core/02_shadows/tools/pareto.py --scene shadow_basic \
    --resolution 1920x1080 --metric mask_iou \
    --out reports/quality/02_shadows_pareto_1080p.md \
    --png reports/quality/02_shadows_pareto_1080p.png
```

The tool refuses to join reports measured at different resolutions and only uses
`--timing frame` reports for the cost axis; per-pass numbers are an upper bound.

## Results so far (P1)

1080p, 2048 shadow map, hard directional reference, exact ray-cast visibility:

| pipeline | taps | mask IoU | MAME | acne | peter-pan | p95 ms | p50 ms |
|---|---|---|---|---|---|---|---|
| `sm` | 1 | 0.999760 | 0.000238 | 0.0031% | 0.0208% | 0.320 | 0.308 |
| `pcf3` | 9 | 0.999758 | 0.000661 | 0.0027% | 0.0213% | 0.343 | 0.319 |
| `pcf5` | 25 | 0.999756 | 0.001113 | 0.0027% | 0.0215% | 0.430 | 0.397 |

The scene has 50 triangles. At this size the shadow-map resolution is nearly
free (256/1024/2048 all measured ~0.32 ms), while the per-pixel filter is the
only measurable cost. PCF against a **hard** reference is not "more accurate":
at a 256 shadow map it improves the binary IoU (0.9963 to 0.9973) but increases
MAME (0.00366 to 0.00854) because it turns aliasing into blur. The soft
footprint (4-6% of receiver pixels) is the filter working as intended; a fair
PCF/PCSS quality judgement needs a soft area-light reference, which is P2.

These absolute numbers are not a game frame: no culling, no engine overhead and
a tiny scene. The relative ordering, the metric protocol and the Pareto are the
deliverables.

## Layout

```
core/02_shadows/
  scenes/             Mitsuba XML (shadow_basic + four Bistro presets)
  src/                math, scene parser, .nxmesh reader, Metal renderer, CLI
  shaders/            G-buffer, depth-only, visibility, shading, debug
  tools/              ray-cast reference, shadow metrics, Pareto, Bistro scaffolding
  notes/              Chinese lesson notes
  README.md           this file (English, tracked)
```

## Notes

* [00_taxonomy.md](notes/00_taxonomy.md) — the map of shadow algorithms, the
  industrial and academic lines, and the phase plan.
* [01_shadow_map_conventions.md](notes/01_shadow_map_conventions.md) — the
  coordinate/depth/winding calibration and the Mitsuba traps.
* [02_pcf.md](notes/02_pcf.md) — PCF, what it fixes, what it does not, and the
  first quality/cost measurements.
* [03_bistro.md](notes/03_bistro.md) — the Bistro asset, the binary import and
  the first large-scene shadow measurements.

## What is next

P2 adds a rectangular area light, PCSS and variance/moment shadow maps, and
starts using a soft reference for the filter comparison. Bistro is ready for
those experiments at 1280x720 with a 2048² or 4096² map; the four presets give
the same geometry under two sun elevations. P4 adds cascades and perspective
shadow maps; P5 shadow volumes; P6 virtual shadow maps, voxel shadows and AVSM.
The Forge port is a later, separate engine-level validation for the winning
pipelines.
