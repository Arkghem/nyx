# Platform and toolchain setup shared by every nyx target.
#
# Everything here is deliberately macos-only: the lab is scoped to Apple
# Silicon + Metal, and pretending otherwise would hide real constraints (no
# ninja, no brew installs from inside the sandbox, no DX12).

# This is a macro on purpose. A function would scope every set() below to
# itself: CMAKE_CXX_STANDARD, the output directories and friends would never
# reach the subdirectories, and targets would silently build as C++14 without
# std::filesystem. Macros run in the caller's scope, which is what a global
# toolchain setup needs.
macro(nx_platform_setup)
    if(NOT APPLE)
        message(FATAL_ERROR "nyx targets macOS only (Metal backend).")
    endif()

    if(NOT CMAKE_OSX_ARCHITECTURES)
        set(CMAKE_OSX_ARCHITECTURES "arm64" CACHE STRING "Target architecture" FORCE)
    endif()

    # NOTE: Objective-C++ must be enabled at the top level, not from inside this
    # function. enable_language() only publishes its variables (such as
    # CMAKE_OBJCXX_COMPILE_OBJECT) into the calling scope, so doing it here
    # breaks generation with "Error required internal CMake variable not set".
    # The root CMakeLists.txt calls enable_language(OBJCXX) right after
    # project().

    set(CMAKE_CXX_STANDARD 17)
    set(CMAKE_CXX_STANDARD_REQUIRED ON)
    set(CMAKE_CXX_EXTENSIONS OFF)

    # Every artefact stays inside the repository: the file sandbox denies
    # writes to ~/Library, /tmp and anywhere else outside the working tree.
    set(NX_BUILD_ROOT "${CMAKE_SOURCE_DIR}/.build" CACHE PATH "Build output root")
    set(NX_METAL_OUTPUT_DIR "${NX_BUILD_ROOT}/shaders" CACHE PATH "Compiled .metallib output")
    # Clang's module cache defaults to somewhere under /var/folders, which the
    # file sandbox refuses. Both the C++ and the Metal compiler get told to keep
    # it inside the repository.
    set(NX_CLANG_MODULE_CACHE "${NX_BUILD_ROOT}/clang-modules"
        CACHE PATH "Clang module cache (must stay inside the repository)")
    set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${NX_BUILD_ROOT}/bin")
    set(CMAKE_LIBRARY_OUTPUT_DIRECTORY "${NX_BUILD_ROOT}/lib")
    set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY "${NX_BUILD_ROOT}/lib")

    foreach(_cfg IN ITEMS DEBUG RELEASE RELWITHDEBINFO MINSIZEREL)
        set(CMAKE_RUNTIME_OUTPUT_DIRECTORY_${_cfg} "${NX_BUILD_ROOT}/bin")
        set(CMAKE_LIBRARY_OUTPUT_DIRECTORY_${_cfg} "${NX_BUILD_ROOT}/lib")
        set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY_${_cfg} "${NX_BUILD_ROOT}/lib")
    endforeach()
endmacro()

# nx_target_defaults(<target>)
# Repository-wide compile settings. Warnings are on but never fatal: the lab
# mixes hand-written experiment code with vendored sources of varying quality.
function(nx_target_defaults target)
    # Stated per target as well as globally, so a target can never end up built
    # against an older standard by accident.
    target_compile_features(${target} PRIVATE cxx_std_17)
    target_compile_options(${target} PRIVATE
        -Wall
        -Wextra
        -Wno-unused-parameter
        -Wno-missing-field-initializers
        "-fmodules-cache-path=${NX_CLANG_MODULE_CACHE}")
    # Static libraries do not carry their own dependencies, so a target that
    # links both nx::profile and nx::io (as experiments legitimately do) ends up
    # passing libnx_io.a twice. That is harmless, and ld's warning about it is
    # pure noise that would train people to ignore linker output.
    target_link_options(${target} PRIVATE "-Wl,-no_warn_duplicate_libraries")
endfunction()
