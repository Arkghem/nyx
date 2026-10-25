# 02_shadows — realtime shadow lab.
#
# Native Metal rather than a Forge example for two reasons: Forge is not checked
# out in this tree, and the algorithms need arbitrary passes and formats (depth
# only, moments, stencil, 3D textures, page tables) that a RenderGraph would
# fight. Forge integration is a later, separate step for the winning pipelines.
#
# The shader list is explicit so common.h is not compiled as a standalone
# translation unit; it is included by every .metal file that needs it.
#
# Comments in this repository are English-only.

nx_experiment(
    NAME    02_shadows
    TYPE    native
    DEPS    metal
    SOURCES src/main.mm
            src/scene.cpp
            src/mesh_format.cpp
            src/renderer.mm
    SHADERS shaders/gbuffer.metal
            shaders/depth_only.metal
            shaders/visibility.metal
            shaders/shading.metal
            shaders/debug.metal
    LINK    nx::io nx::profile
)
