# scenes

The scene source of truth. **The Mitsuba XML is the only source of truth**: any
glTF or parameters handed to The-Forge are exported from it. Geometry and cameras
are never authored twice.

The reason is practical. When the two sides disagree, the difference image shows
"everything is different everywhere", and a difference image like that localises
nothing. A single mismatch in camera, resolution or colour space makes the quality
metrics meaningless.

## Conventions

- **Resolution and camera live in the scene file.** Scripts do not override them;
  `render_ref.py` reads them back and prints them. That is the point: both sides
  take the film size from the same line of text.
- One scene per file, named for what it is for (`stage0_checkerboard.xml`).
- Reference image naming: `references/<scene>_<variant>_<spp>spp_seed<seed>.exr`.
- Scenes private to one experiment live in `core/<experiment>/scenes/`. Scenes
  shared across stages live here.

## Current scenes

| Scene | Purpose |
|---|---|
| `stage0_checkerboard.xml` | Stage 0 alignment. A checkerboard is very sensitive to half-pixel offsets and colour space errors, and insensitive to shading bugs — exactly the property a calibration target needs |

Checking that a scene loads is much faster than rendering it:

```bash
source env.sh
python3 -c "
import mitsuba as mi; mi.set_variant('metal_ad_rgb')
scene = mi.load_file('scenes/stage0_checkerboard.xml')
print('ok', scene.sensors()[0].film().size())
"
```

## Traps hit while writing scenes

- In Mitsuba 3 an **`area` emitter must be nested inside a shape** and must not
  carry its own `to_world` — it inherits the parent shape's transform. Writing it
  standalone fails with `Found a 'to_world' transformation -- this is not allowed`.
- The `checkerboard` texture **has no `scale` property**. Scaling goes through
  `<transform name="to_uv"><scale value="4"/></transform>`.
- A misspelled property is not silently ignored: Mitsuba reports
  `Found N unreferenced property` and refuses to load the scene. That is friendly,
  but the error points at the outermost node, so the actual problem takes a moment
  to find.
