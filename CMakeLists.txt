# nyx — graphics lab root build file.
#
# Layout
#   core/<experiment>/   one self-contained experiment per directory
#   libs/                reusable code shared by experiments (nx::io, nx::profile, ...)
#   third_party/         third-party sources, registered via cmake/NxDependencies.cmake
#   forge/               The-Forge submodule, consumed as a prebuilt static library
#
# Default behaviour: only the active experiment (recorded in .nx-active by
# scripts/use.sh) is part of the default build. Every other experiment is still
# configured but excluded, so `cmake --build . --target <name>` keeps working
# for any of them. Passing -DNX_BUILD_ALL=ON builds everything.

cmake_minimum_required(VERSION 3.24)

project(nyx LANGUAGES C CXX)

# Everything that touches the Metal API is Objective-C++, so the language has to
# be enabled. It must happen at this scope: enable_language() only publishes
# CMAKE_OBJCXX_* into the calling scope, and hiding it inside a function breaks
# generation.
enable_language(OBJCXX)

list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")

include(NxPlatform)
include(NxDependencies)
include(NxMetal)
include(NxCore)
include(NxForge)
include(NxMitsuba)

nx_platform_setup()

# ---------------------------------------------------------------------------
# Compilation database.
#
# CMake initialises CMAKE_EXPORT_COMPILE_COMMANDS as a *cache* variable, so it is
# always "defined" — an empty string when neither the environment variable nor -D
# set it. The fallback therefore has to test for empty rather than for undefined,
# and leaves an explicit OFF alone.
# ---------------------------------------------------------------------------
if(CMAKE_EXPORT_COMPILE_COMMANDS STREQUAL "")
    set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
endif()

# clangd and most editors look for compile_commands.json at the project root, but
# the generated file lives in the build tree — and there is one per preset. Point
# a relative symlink at it so tooling works without per-editor configuration.
#
# The link is gitignored: it is generated state, and it follows whichever preset
# was configured last.
if(CMAKE_EXPORT_COMPILE_COMMANDS)
    set(_nx_db_link "${CMAKE_SOURCE_DIR}/compile_commands.json")
    if(EXISTS "${_nx_db_link}" AND NOT IS_SYMLINK "${_nx_db_link}")
        # A real file someone put there on purpose. Do not clobber it.
        message(STATUS "nyx: compile_commands.json exists at the root and is not a "
                       "symlink; leaving it alone")
    else()
        file(RELATIVE_PATH _nx_db_target "${CMAKE_SOURCE_DIR}"
             "${CMAKE_BINARY_DIR}/compile_commands.json")
        file(REMOVE "${_nx_db_link}")
        file(CREATE_LINK "${_nx_db_target}" "${_nx_db_link}" SYMBOLIC)
        message(STATUS "nyx: compile_commands.json -> ${_nx_db_target}")
    endif()
endif()

option(NX_BUILD_ALL "Configure every experiment for the default build" OFF)

set(NX_ACTIVE "" CACHE STRING
    "Active experiment name; empty means auto-detect from .nx-active")

if(NOT NX_ACTIVE AND EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/.nx-active")
    file(READ "${CMAKE_CURRENT_SOURCE_DIR}/.nx-active" NX_ACTIVE)
    string(STRIP "${NX_ACTIVE}" NX_ACTIVE)
endif()

if(NX_ACTIVE)
    message(STATUS "nyx: active experiment = ${NX_ACTIVE}")
else()
    message(STATUS "nyx: no active experiment — run ./scripts/use.sh <experiment>. "
                   "Configuring every experiment with EXCLUDE_FROM_ALL.")
endif()

# ---------------------------------------------------------------------------
# Shared libraries. Experiments link these as nx::io, nx::profile, nx::metrics.
# ---------------------------------------------------------------------------
add_subdirectory(libs)

# ---------------------------------------------------------------------------
# Experiments.
# ---------------------------------------------------------------------------
nx_collect_experiments(NX_EXPERIMENTS)

if(NOT NX_EXPERIMENTS)
    message(STATUS "nyx: no experiments found under core/")
endif()

foreach(nx_exp IN LISTS NX_EXPERIMENTS)
    if(NX_BUILD_ALL OR NX_ACTIVE STREQUAL "" OR nx_exp STREQUAL NX_ACTIVE)
        add_subdirectory("core/${nx_exp}")
    else()
        add_subdirectory("core/${nx_exp}" EXCLUDE_FROM_ALL)
    endif()
endforeach()

message(STATUS "nyx: experiments = ${NX_EXPERIMENTS}")
