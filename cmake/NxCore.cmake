# Experiment plumbing.
#
# An experiment is a self-contained directory under core/ with an
# experiment.cmake that declares what it is and what it needs:
#
#   nx_experiment(
#     NAME    05_svgf_denoise
#     TYPE    native                 # native | forge | python
#     DEPS    metal                  # forge | metal | mitsuba | <nx_dependency name>
#     SOURCES src/main.mm
#     SHADERS shaders/*.metal
#     LINK    nx::io nx::metrics nx::profile
#   )
#
# Dependencies are resolved lazily: a dependency that is not declared is never
# looked up, so an experiment that needs nothing configures even before Forge is
# checked out.

# nx_collect_experiments(<out_var>)
# Sorted names of every directory under core/ that carries an experiment.cmake.
# Directories starting with an underscore are reserved (core/_template).
function(nx_collect_experiments out_var)
    file(GLOB _entries RELATIVE "${CMAKE_SOURCE_DIR}/core" "${CMAKE_SOURCE_DIR}/core/*")
    set(_found "")
    foreach(_entry IN LISTS _entries)
        if(_entry MATCHES "^_")
            continue()
        endif()
        if(IS_DIRECTORY "${CMAKE_SOURCE_DIR}/core/${_entry}"
           AND EXISTS "${CMAKE_SOURCE_DIR}/core/${_entry}/experiment.cmake")
            list(APPEND _found "${_entry}")
        endif()
    endforeach()
    list(SORT _found)
    set(${out_var} "${_found}" PARENT_SCOPE)
endfunction()

# nx_expand_globs(<out_var> <entry>...)
# Resolves entries relative to the current source dir. Entries containing '*'
# are globbed recursively with CONFIGURE_DEPENDS so that dropping a new source
# file into an experiment is enough to get it compiled.
function(nx_expand_globs out_var)
    set(_result "")
    foreach(_entry IN LISTS ARGN)
        if(_entry MATCHES "\\*")
            file(GLOB_RECURSE _matched CONFIGURE_DEPENDS
                "${CMAKE_CURRENT_SOURCE_DIR}/${_entry}")
            list(APPEND _result ${_matched})
        else()
            list(APPEND _result "${CMAKE_CURRENT_SOURCE_DIR}/${_entry}")
        endif()
    endforeach()
    set(${out_var} "${_result}" PARENT_SCOPE)
endfunction()

# nx_resolve_deps(<deps...> <experiment_name>)
# Turns dependency names into link targets, setting NX_RESOLVED_DEPS in the
# calling scope.
function(nx_resolve_deps experiment_name)
    set(_deps ${ARGN})
    set(_targets "")

    foreach(_dep IN LISTS _deps)
        if(_dep STREQUAL "metal")
            nx_metal_frameworks(_t)
            list(APPEND _targets ${_t})
        elseif(_dep STREQUAL "forge")
            nx_forge_target(_t)
            if(_t)
                list(APPEND _targets ${_t})
            endif()
        elseif(_dep STREQUAL "mitsuba")
            nx_mitsuba_target(_t)
            if(_t)
                list(APPEND _targets ${_t})
            endif()
        elseif(TARGET nx::dep::${_dep})
            list(APPEND _targets "nx::dep::${_dep}")
        else()
            message(WARNING
                "experiment ${experiment_name}: dependency '${_dep}' is neither a "
                "built-in (metal/forge/mitsuba) nor a registered nx_dependency(). "
                "Add it to cmake/NxDependencies.cmake and third_party/README.md.")
        endif()
    endforeach()

    set(NX_RESOLVED_DEPS "${_targets}" PARENT_SCOPE)
endfunction()

# nx_experiment(NAME <name> TYPE <type> [DEPS ...] [SOURCES ...] [SHADERS ...]
#               [LINK ...] [SCRIPT <path>] [ARGS ...] [DEFINITIONS ...])
function(nx_experiment)
    cmake_parse_arguments(E
        ""
        "NAME;TYPE;SCRIPT"
        "DEPS;SOURCES;SHADERS;LINK;ARGS;DEFINITIONS"
        ${ARGN})

    if(NOT E_NAME)
        message(FATAL_ERROR "nx_experiment(): NAME is required")
    endif()
    if(NOT E_TYPE)
        set(E_TYPE "native")
    endif()

    if(TARGET ${E_NAME})
        message(FATAL_ERROR "nx_experiment(): target '${E_NAME}' already exists")
    endif()

    nx_resolve_deps("${E_NAME}" ${E_DEPS})

    # ------------------------------------------------------------------
    # python experiments: no compiled artefact, just a reproducible entry
    # point that can be driven from the build system.
    # ------------------------------------------------------------------
    if(E_TYPE STREQUAL "python")
        if(NOT E_SCRIPT)
            message(FATAL_ERROR "nx_experiment(${E_NAME}): TYPE python needs SCRIPT")
        endif()
        nx_mitsuba_python(_py)
        if(NOT _py)
            message(STATUS "experiment ${E_NAME}: skipped, no python interpreter")
            return()
        endif()
        add_custom_target(${E_NAME}
            COMMAND "${_py}" "${CMAKE_SOURCE_DIR}/${E_SCRIPT}" ${E_ARGS}
            WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
            COMMENT "experiment ${E_NAME} (python)"
            VERBATIM)
        return()
    endif()

    # ------------------------------------------------------------------
    # native / forge experiments: a real executable.
    # ------------------------------------------------------------------
    if(E_TYPE STREQUAL "forge" AND NOT "forge" IN_LIST E_DEPS)
        message(WARNING "experiment ${E_NAME}: TYPE forge but DEPS does not list forge")
    endif()

    nx_expand_globs(E_SOURCES ${E_SOURCES})
    if(NOT E_SOURCES)
        message(FATAL_ERROR "nx_experiment(${E_NAME}): no sources found")
    endif()

    add_executable(${E_NAME} ${E_SOURCES})
    nx_target_defaults(${E_NAME})

    if(NX_RESOLVED_DEPS)
        target_link_libraries(${E_NAME} PRIVATE ${NX_RESOLVED_DEPS})
    endif()
    if(E_LINK)
        target_link_libraries(${E_NAME} PRIVATE ${E_LINK})
    endif()
    if(E_DEFINITIONS)
        target_compile_definitions(${E_NAME} PRIVATE ${E_DEFINITIONS})
    endif()

    if(E_SHADERS)
        nx_expand_globs(E_SHADERS ${E_SHADERS})
        nx_add_metal_library(${E_NAME} _metallib ${E_SHADERS})
        add_dependencies(${E_NAME} ${E_NAME}_metallib)
        target_compile_definitions(${E_NAME} PRIVATE
            NX_SHADER_DIR="${NX_METAL_OUTPUT_DIR}")
    endif()

    # Running an experiment from the build tree is the common case, so put the
    # repository root on the default working directory.
    set_target_properties(${E_NAME} PROPERTIES
        RUNTIME_OUTPUT_DIRECTORY "${NX_BUILD_ROOT}/bin")

    message(STATUS "experiment ${E_NAME}: type=${E_TYPE} deps='${E_DEPS}'")
endfunction()
