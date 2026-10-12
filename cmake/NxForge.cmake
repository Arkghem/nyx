# The-Forge as a dependency.
#
# The-Forge ships no CMake build at all (zero CMakeLists.txt in the whole
# repository), so nyx never tries to build it here. Instead:
#
#   * scripts/build_forge.sh drives The-Forge's own Xcode project with
#     xcodebuild and produces libThe-Forge.a
#   * this module only locates that artefact and the headers around it
#
# Until the library exists, nx::forge is a placeholder target that forces a
# link error whose symbol name says exactly what to run. Configuration stays
# green so experiments that do not use Forge keep working.

set(NX_FORGE_ROOT "${CMAKE_SOURCE_DIR}/forge" CACHE PATH "The-Forge checkout")

# nx_forge_library(<out_var>) — absolute path to libThe-Forge.a, or "".
function(nx_forge_library out_var)
    set(_result "")
    if(IS_DIRECTORY "${NX_FORGE_ROOT}")
        file(GLOB _candidates
            "${NX_FORGE_ROOT}/Examples_3/Unit_Tests/macOS_Xcode/The-Forge/Bin/*/libThe-Forge.a"
            "${NX_FORGE_ROOT}/Examples_3/Unit_Tests/macOS_Xcode/The-Forge/Bin/libThe-Forge.a")
        if(_candidates)
            list(GET _candidates 0 _result)
        endif()
    endif()
    set(${out_var} "${_result}" PARENT_SCOPE)
endfunction()

# nx_forge_includes(<out_var>) — header search paths for The-Forge.
function(nx_forge_includes out_var)
    set(_dirs "")
    if(NOT IS_DIRECTORY "${NX_FORGE_ROOT}")
        set(${out_var} "" PARENT_SCOPE)
        return()
    endif()

    # Every directory literally named Interfaces is part of the public API
    # surface, which is how The-Forge's own Xcode projects assemble their
    # header search paths.
    file(GLOB_RECURSE _iface
        LIST_DIRECTORIES TRUE
        "${NX_FORGE_ROOT}/Common_3/*/*/Interfaces"
        "${NX_FORGE_ROOT}/Common_3/*/*/*/Interfaces")

    foreach(_dir IN LISTS _iface)
        if(IS_DIRECTORY "${_dir}")
            list(APPEND _dirs "${_dir}")
        endif()
    endforeach()

    foreach(_rel IN ITEMS
            "Common_3/Utilities/Math"
            "Common_3/Utilities/Interfaces"
            "Common_3/Utilities/ThirdParty/OpenSource"
            "Common_3/OS/Interfaces"
            "Common_3/OS/Interfaces/IO"
            "Common_3/Graphics/ThirdParty/OpenSource"
            "Common_3/Resources/ResourceLoader/Interfaces")
        if(IS_DIRECTORY "${NX_FORGE_ROOT}/${_rel}")
            list(APPEND _dirs "${NX_FORGE_ROOT}/${_rel}")
        endif()
    endforeach()

    list(REMOVE_DUPLICATES _dirs)
    set(${out_var} "${_dirs}" PARENT_SCOPE)
endfunction()

# nx_forge_target(<out_var>) — always yields a usable target name.
function(nx_forge_target out_var)
    if(TARGET nx::forge)
        set(${out_var} nx::forge PARENT_SCOPE)
        return()
    endif()

    nx_forge_library(_lib)

    if(NOT _lib)
        # Placeholder. Referencing this symbol turns "library not built yet"
        # into a link error that names the fix.
        add_library(nx_forge_placeholder INTERFACE)
        target_link_options(nx_forge_placeholder INTERFACE
            "-Wl,-U,_nx_forge_not_built__run_scripts_build_forge_sh")
        add_library(nx::forge ALIAS nx_forge_placeholder)
        if(NOT IS_DIRECTORY "${NX_FORGE_ROOT}")
            message(STATUS
                "nx: forge/ is not checked out yet. Forge experiments will not link "
                "until you run: git submodule update --init --recursive")
        else()
            message(STATUS
                "nx: libThe-Forge.a not found. Build it first: ./scripts/build_forge.sh")
        endif()
        set(${out_var} nx::forge PARENT_SCOPE)
        return()
    endif()

    add_library(nx::forge STATIC IMPORTED GLOBAL)
    set_target_properties(nx::forge PROPERTIES IMPORTED_LOCATION "${_lib}")

    nx_forge_includes(_incs)
    if(_incs)
        set_property(TARGET nx::forge PROPERTY INTERFACE_INCLUDE_DIRECTORIES "${_incs}")
    endif()

    # Frameworks and system libraries The-Forge links against. This list is a
    # first approximation: it has to be confirmed against the real archive
    # during init, because it can only be read off a built libThe-Forge.a.
    set_property(TARGET nx::forge PROPERTY INTERFACE_LINK_LIBRARIES
        "-framework Metal"
        "-framework MetalKit"
        "-framework AppKit"
        "-framework QuartzCore"
        "-framework Foundation"
        "-framework CoreFoundation"
        "-framework IOKit"
        "-framework UniformTypeIdentifiers"
        "-lz")

    message(STATUS "nx: forge library = ${_lib}")
    set(${out_var} nx::forge PARENT_SCOPE)
endfunction()
