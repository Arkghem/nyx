# scripts

Workflow scripts. Run all of them from the repository root, and **`source env.sh`
in every new shell first**.

| Script | Purpose |
|---|---|
| `check_env.py` | Environment self-check. Reports PASS / FAIL / WARN per item, never installs, and reflects the result in its exit code |
| `use.sh <exp>` | Select the active experiment: writes `.nx-active`, repoints the `entry` symlink |
| `new_exp.sh <name> [--link]` | Create an experiment from `core/_template`; it builds as generated |
| `build.sh [--release\|--all\|--configure-only\|<target>]` | Configure and build |
| `run.sh [args...]` | Run the active experiment, building it first if needed |
| `bench.sh [<exp>] [--warmup N] [--frames N] [--repeat N] [--metric M] [--baseline] [-- <args>]` | Benchmark and write a JSON report |
| `bench_pick.py` | Pick the best of several runs. Between-run variance measured 81% here, so a single run is not a measurement. Normally called by `bench.sh` |
| `perf_gate.py --candidate <json> [--baseline <json>] [--threshold 0.10] [--metric p95]` | Performance gate |
| `render_ref.py --scene <xml> [--spp N] [--seed N] [--out PATH] [--variant V]` | Render a Mitsuba reference image |
| `nx_io.py` | Shared library, not an executable: EXR write/read and tone mapping. **All image writes go through this** |
| `build_forge.sh [--release\|--dry-run]` | Build `libThe-Forge.a` with xcodebuild |

## Two conventions

**1. Always write images with `nx_io.write_exr()`.**

`mi.util.write_bitmap()` is asynchronous: it queues the write and returns before the
file exists. Checking straight afterwards yields "No such file or directory", which
looks exactly like a permissions problem and is not one. `nx_io.write_exr` drains
Mitsuba's thread pool and confirms the file has settled (measured: 5/5 writes land,
versus 0/5 without it).

**2. Benchmarkable experiments implement the `--bench-*` contract.**

```
--bench-warmup <n>   frames rendered before measurement starts
--bench-frames <n>   number of frames measured
--bench-out <path>   where the JSON report is written
```

`bench.sh` drives any experiment through these three flags, so it needs to know
nothing about what the experiment does. Programs that do not own their command line
(The-Forge unit tests, for instance) can use the environment variable instead:
`NYX_BENCH="<warmup>,<frames>,<out>"`. The contract is defined in
`libs/profile/include/nx/profile/bench_options.h`.

## Typical flow

```bash
source env.sh
./scripts/check_env.py

# Quality
./scripts/render_ref.py --scene scenes/stage0_checkerboard.xml --spp 2048 --seed 0

# Performance
./scripts/bench.sh 01_perf_probe --baseline     # record a baseline
./scripts/bench.sh 01_perf_probe                # measure again
./scripts/perf_gate.py --candidate "$(ls -t reports/bench/01_perf_probe_*.json | grep -v run | head -1)"
```
