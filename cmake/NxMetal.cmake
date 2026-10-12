# Metal shader compilation.
#
# Experiments declare .metal sources in experiment.cmake; this module turns
# them into a single .metallib per target and exposes its directory so the C++
# side can load it at runtime (NX_SHADER_DIR).

# nx_add_metal_library(<target> <out_metallib_var> <sources...>)
#
# Compiles each .metal file to .air and links them into
# ${NX_METAL_OUTPUT_DIR}/<target>.metallib.
function(nx_add_metal_library target out_var)
    set(_sources ${ARGN})
    if(NOT _sources)
        message(FATAL_ERROR "nx_add_metal_library(${target}): no sources given")
    endif()

    set(_air_dir "${CMAKE_BINARY_DIR}/metal/${target}")
    set(_airs "")

    foreach(_src IN LISTS _sources)
        if(NOT EXISTS "${_src}")
            message(FATAL_ERROR "nx_add_metal_library(${target}): missing source ${_src}")
        endif()
        get_filename_component(_name "${_src}" NAME_WE)
        set(_air "${_air_dir}/${_name}.air")

        add_custom_command(
            OUTPUT "${_air}"
            COMMAND "${CMAKE_COMMAND}" -E make_directory "${_air_dir}"
            COMMAND xcrun -sdk macosx metal
                    "-fmodules-cache-path=${NX_CLANG_MODULE_CACHE}"
                    -c "${_src}" -o "${_air}"
            DEPENDS "${_src}"
            COMMENT "Metal: compiling ${_name}.metal"
            VERBATIM)
        list(APPEND _airs "${_air}")
    endforeach()

    set(_metallib "${NX_METAL_OUTPUT_DIR}/${target}.metallib")
    add_custom_command(
        OUTPUT "${_metallib}"
        COMMAND "${CMAKE_COMMAND}" -E make_directory "${NX_METAL_OUTPUT_DIR}"
        COMMAND xcrun -sdk macosx metallib ${_airs} -o "${_metallib}"
        DEPENDS ${_airs}
        COMMENT "Metal: linking ${target}.metallib"
        VERBATIM)

    add_custom_target(${target}_metallib DEPENDS "${_metallib}")
    set(${out_var} "${_metallib}" PARENT_SCOPE)
endfunction()

# nx_metal_frameworks(<out_var>)
# The system frameworks a Metal compute experiment needs. MetalKit/AppKit are
# included so windowed experiments do not need to ask again.
function(nx_metal_frameworks out_var)
    if(NOT TARGET nx_sys_metal)
        add_library(nx_sys_metal INTERFACE)
        target_link_libraries(nx_sys_metal INTERFACE
            "-framework Metal"
            "-framework MetalKit"
            "-framework Foundation"
            "-framework QuartzCore")
    endif()
    set(${out_var} nx_sys_metal PARENT_SCOPE)
endfunction()
