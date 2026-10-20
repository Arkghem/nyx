# nyx

A graphics lab: working through the techniques in PBRT, RTR4, GPU Pro and GPU Zen
one at a time, and checking each one against a reference.

The whole loop is one sentence:

```
book (theory) -> Mitsuba (ground truth) -> The-Forge (realtime) -> Python metrics (quality) -> GPU timing (cost)
```

Mitsuba produces the standard answer. The realtime renderer's deviation from it is
quantified by image metrics and difference images; its cost is quantified by GPU
timing.

> Note: this repository is developed with the help of a coding agent, and the two
> places where that work is recorded — `AGENTS.md` (agent instructions) and `docs/`
> (environment archive, decision log, performance methodology) — are deliberately
> **not tracked** (see `.gitignore`). They are the lab notebook, not the artefact.
>
> That puts an obligation on the published tree: it has to stand on its own.
> Environment traps are documented in the comments of the code they affect, and
> everything needed to build and use the repository lives in this file or in a
> tracked `README.md`.

---

## Quick start

```bash
source env.sh                  # required in every new shell
./scripts/check_env.py         # self-check: reports, never installs

./scripts/use.sh 00_envcheck   # select an experiment
./scripts/build.sh             # configure + build
./scripts/run.sh               # run it
```

On a fresh clone, `check_env.py` lists everything that is still missing
(virtual environment, Python packages, the The-Forge submodule).

### Editor integration

Configuring generates a compilation database and symlinks it to the repository
root as `compile_commands.json`, so clangd and most editors work with no extra
configuration:

```bash
cmake --preset macos-debug     # writes .build/cmake/macos-debug/compile_commands.json
                               # and points ./compile_commands.json at it
```

A plain `cmake -S . -B <dir>` works too and produces the database as well; if you
pick your own build directory, keep it under `.build/` so it stays ignored. An
explicit `-DCMAKE_EXPORT_COMPILE_COMMANDS=OFF` is respected.

The link follows whichever build directory was configured last, and it is
generated state, so it is not tracked. It covers every experiment, not only the
active one — but re-run configure after adding sources, which `./scripts/build.sh`
does for you.

---

## Adding an experiment

```bash
./scripts/new_exp.sh 05_svgf_denoise --link
./scripts/build.sh
./scripts/run.sh
```

The generated experiment compiles and runs immediately. The only file you edit is
`core/05_svgf_denoise/experiment.cmake`, which declares the type
(`native` / `forge` / `python`), the dependencies and the sources.

Dependencies are resolved lazily: anything not declared is never looked up, so an
empty experiment configures and builds even before The-Forge has been checked out.

Existing experiments:

| Experiment | Purpose |
|---|---|
| `00_envcheck` | Native toolchain check: CMake to ObjC++ to Metal to timing to EXR, end to end |
| `01_perf_probe` | Reference implementation of the benchmark contract, driven by `bench.sh` / `perf_gate.py` |
| `02_shadows` | Realtime shadow lab: shadow map + PCF, offline Mitsuba/ray-cast truth, visibility metrics, quality/cost Pareto. See `core/02_shadows/README.md` |
| `_template` | Template copied by `new_exp.sh` (never built) |

---

## Layout

```
core/        experiments: one self-contained directory each
libs/        shared code: nx::io (EXR), nx::metrics, nx::profile (timing)
third_party/ third-party dependencies and their registry
forge/       The-Forge submodule
cmake/       build modules (experiment macro, dependency entry point, Metal, Forge, Mitsuba)
scripts/     workflow scripts
scenes/      scene source of truth (Mitsuba XML)
references/  Mitsuba reference images (the standard answer)
outputs/     realtime renderer output
reports/     quality and performance reports (baselines/ is tracked, the rest is not)
patches/     patches exported from The-Forge
```

`docs/` and `AGENTS.md` also exist in the working tree but are untracked local notes.

---

## Judging

Both quality and cost are tracked against a baseline, and both act as gates.

```bash
# Quality: linear-light PSNR/MAE/SSIM and a difference image
./scripts/render_ref.py --scene scenes/stage0_checkerboard.xml --spp 2048 --seed 0
./scripts/compare.py --reference <reference.exr> --test <render.exr> \
    --mask interior --out-diff <diff.exr> --out-png <diff.png>

# 02_shadows: independent visibility truth and shadow-specific metrics
python3 scripts/export_scene.py --all
python3 core/02_shadows/tools/raycast_ref.py \
    --scene .cache/scenes/shadow_basic.nxscene --out references/_smoke/shadow_basic_mask.exr
python3 core/02_shadows/tools/shadow_metrics.py \
    --reference references/_smoke/shadow_basic_mask.exr \
    --test outputs/02_shadows/shadow_basic_sm_768x768_sm2048_b0.00100_seed0_vis.exr
python3 core/02_shadows/tools/pareto.py --scene shadow_basic --resolution 1920x1080

# Performance
./scripts/bench.sh 01_perf_probe --baseline      # record a baseline
./scripts/bench.sh 01_perf_probe                 # measure again
./scripts/perf_gate.py --candidate reports/bench/<report>.json
```

The performance gate has a few hard rules, all of them learned the hard way on
this machine:

- **Only compare like with like.** A report measured with a different timer
  source or at a different resolution is reported as "not comparable" rather
  than compared.
- **Run the benchmark several times and keep the best run.** Between-run variance
  measured 81% here, while within a single run p95/p50 was only 1.4 — a single
  run is not a measurement.
- **Keep the measured workload long enough.** Sub-millisecond dispatches are
  dominated by scheduling noise: p95/p50 was 3.5 at 0.6 ms per dispatch and 1.04
  at 5 ms.

The reasoning behind these numbers, and the full device capability probe, are in
the comments where they matter: `scripts/bench_pick.py`,
`libs/profile/include/nx/profile/gpu_timer.h` and
`core/01_perf_probe/src/main.mm`.
