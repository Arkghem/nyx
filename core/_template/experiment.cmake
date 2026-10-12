# Experiment declaration — the only file you normally edit.
#
# The rules that keep this flexible:
#
#   * TYPE decides what gets built. native and forge produce an executable,
#     python registers a custom target that runs a script.
#   * DEPS decides what is looked up. Anything not listed is never searched
#     for, so an experiment that needs nothing configures even before Forge is
#     checked out. Valid built-ins are metal, forge and mitsuba; anything else
#     must be registered with nx_dependency() in cmake/NxDependencies.cmake
#     (and listed in third_party/README.md).
#   * SOURCES and SHADERS accept globs and are re-globbed automatically when
#     files are added.
#   * LINK takes the shared libraries: nx::io, nx::metrics, nx::profile.
#
# Comments in this repository are English-only.

nx_experiment(
    NAME    _template
    TYPE    native
    DEPS    metal
    SOURCES src/main.mm
    SHADERS shaders/pass.metal
    LINK    nx::io nx::profile
)
