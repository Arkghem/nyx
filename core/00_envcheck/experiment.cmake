# Environment check experiment.
#
# Its only job is to prove that the whole native toolchain works end to end:
#
#   CMake configure -> Objective-C++ compile -> Metal shader compile
#   -> metallib link -> Metal runtime -> GPU timestamps -> EXR write
#
# It is deliberately independent of The-Forge, so a broken Forge submodule
# never blocks the rest of the lab from being usable.

nx_experiment(
    NAME    00_envcheck
    TYPE    native
    DEPS    metal
    SOURCES src/main.mm
    SHADERS shaders/pattern.metal
    LINK    nx::io nx::profile
)
