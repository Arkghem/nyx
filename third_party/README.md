# Third-party dependencies

**This is the only dependency registry.** Any third-party code entering nyx has to
satisfy two rules:

1. It is pulled in through `nx_dependency()` in `cmake/NxDependencies.cmake`.
   Experiments must never call `find_package()` directly — otherwise dependencies
   scatter across the tree and can neither be audited nor pinned.
2. It is registered in the table below: version, acquisition mode, licence and
   who uses it.

## Acquisition modes, in order of preference

| Mode | When to use it | Where it lands |
|---|---|---|
| `system` | Already present on the machine (Homebrew, SDK) | Probed read-only. **nyx never installs anything** — `brew install` writes to `/opt/homebrew`, which the file sandbox refuses |
| `fetchcontent` | Preferred. Pin a URL plus a SHA256: verifiable and faster than a clone | `third_party/_deps/` |
| `vendored` | Libraries whose source has to be modified | `third_party/<name>/` |

## Registry

| Name | Version | Mode | Licence | Used by | Notes |
|---|---|---|---|---|---|
| tinyexr | `v1.0.13` (URL + SHA256) | `fetchcontent` | BSD-3-Clause | `nx::io` | EXR input/output. Ships miniz (`deps/miniz/miniz.c`), compiled into the `nx_dep_tinyexr_bundled` static library. Its plain-zlib code path is commented out upstream, so miniz is the only option |

```cmake
# The actual declaration, from libs/io/CMakeLists.txt
nx_dependency(
    NAME           tinyexr
    MODE           fetchcontent
    URL            https://github.com/syoyo/tinyexr/archive/refs/tags/v1.0.13.tar.gz
    URL_HASH       SHA256=01edf1e18e32e5503fdd2a35d62bb593109daa392324cec0157b150e5fd68077
    SKIP_CMAKE                 # take the sources, not upstream's build configuration
    SOURCES        deps/miniz/miniz.c
    INCLUDE_SUBDIRS deps/miniz
    DEFINITIONS    TINYEXR_USE_MINIZ=1
    REQUIRED)
```

## Planned, not yet present

| Name | Purpose | Stage | Notes |
|---|---|---|---|
| OIDN | Denoiser, to validate the pipeline | 6 | Use it first, then move to NRD/SVGF |
| FSR 2/3 | Upscaling | 6 | Limited macOS support; may need a cloud machine |
| FLIP evaluator | Perceptual metric | 1 | Could also live purely on the Python side |
| OpenEXR (python) | Independent EXR I/O from Python | spare | Python currently goes through Mitsuba; add this only if that becomes a problem |

## Anti-patterns

Do not introduce the following:

- **Anything that needs `brew install`.** The sandbox refuses writes to
  `/opt/homebrew`, so it cannot be installed. Vendor it or fetch the source.
- **GPL / AGPL libraries.** Once a copyleft dependency is in a graphics stack it is
  very hard to get out.
- **Libraries whose CMake project pollutes global settings.** Use `SKIP_CMAKE` to
  take the sources without letting them `add_subdirectory()` their way into our
  build options.
