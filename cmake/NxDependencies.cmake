# Single entry point for third-party code.
#
# Rules (see third_party/README.md):
#   * Experiments must never call find_package() for a third-party library.
#   * Every dependency goes through nx_dependency() so the whole set is
#     auditable from one file.
#   * Every dependency must be registered in third_party/README.md with its
#     pinned version, acquisition mode and licence.
#
# Acquisition modes:
#   fetchcontent : downloaded at configure time into third_party/_deps/
#   system       : already installed on the machine (probed read-only; nyx
#                  never installs anything, the sandbox forbids writing to
#                  /opt/homebrew)
#   vendored     : source committed under third_party/<name>/

set(NX_THIRD_PARTY_DIR "${CMAKE_SOURCE_DIR}/third_party" CACHE PATH "Third-party source root")
set(FETCHCONTENT_BASE_DIR "${NX_THIRD_PARTY_DIR}/_deps" CACHE PATH "FetchContent download root" FORCE)
set(FETCHCONTENT_QUIET OFF)

include(FetchContent)

# nx_dependency(
#     NAME <name>
#     [MODE fetchcontent|system|vendored]
#     [REQUIRED]
#     # fetchcontent
#     [GIT_REPOSITORY <url> GIT_TAG <pin>] [SKIP_CMAKE]
#     # vendored
#     [PATH <dir relative to third_party/>]
#     # system
#     [PACKAGE <find_package name>]
#     # all modes
#     [INCLUDE_SUBDIRS <dir>...] [SOURCES <file>...] [DEFINITIONS <def>...]
#     [LIBRARIES <lib>...])
#
# On success defines:
#   nx::dep::<name>          — an INTERFACE target carrying includes, defines
#                              and links
#   NX_DEP_<name>_FOUND=TRUE in the calling scope
# On failure (non-REQUIRED) the target is simply not created and
# NX_DEP_<name>_FOUND is FALSE, so configuration stays green.
function(nx_dependency)
    cmake_parse_arguments(D
        "SKIP_CMAKE;REQUIRED;NO_SUBMODULES"
        "NAME;MODE;GIT_REPOSITORY;GIT_TAG;URL;URL_HASH;PACKAGE;PATH"
        "INCLUDE_SUBDIRS;SOURCES;DEFINITIONS;LIBRARIES"
        ${ARGN})

    if(NOT D_NAME)
        message(FATAL_ERROR "nx_dependency(): NAME is required")
    endif()

    string(TOLOWER "${D_NAME}" _lower)
    set(_alias "nx::dep::${D_NAME}")
    set(_real "nx_dep_${_lower}")

    if(TARGET ${_alias})
        return()
    endif()

    if(NOT D_MODE)
        set(D_MODE "system")
    endif()

    set(_root "")
    set(_found TRUE)

    if(D_MODE STREQUAL "fetchcontent")
        if(NOT D_URL AND (NOT D_GIT_REPOSITORY OR NOT D_GIT_TAG))
            message(FATAL_ERROR
                "nx_dependency(${D_NAME}): fetchcontent needs URL (+URL_HASH) or "
                "GIT_REPOSITORY + GIT_TAG")
        endif()

        # SOURCE_SUBDIR pointing at a directory that does not exist stops
        # FetchContent from running the upstream CMakeLists.txt. nyx wants the
        # sources, not somebody else's build configuration.
        set(_extra_opts "")
        if(D_SKIP_CMAKE)
            list(APPEND _extra_opts SOURCE_SUBDIR "cmake/nyx-intentionally-not-a-directory")
        endif()
        if(D_NO_SUBMODULES)
            # Only meaningful with CMP0097 NEW: under the old policy an empty
            # GIT_SUBMODULES means "all of them".
            list(APPEND _extra_opts GIT_SUBMODULES "")
        endif()

        if(D_URL)
            # A release archive is preferred over a clone: no history, no
            # submodules, and the hash makes the pin verifiable.
            if(NOT D_URL_HASH)
                message(WARNING
                    "nx_dependency(${D_NAME}): URL given without URL_HASH, the "
                    "download cannot be verified")
            endif()
            FetchContent_Declare(${D_NAME}
                URL      "${D_URL}"
                URL_HASH "${D_URL_HASH}"
                ${_extra_opts})
        else()
            # GIT_PROGRESS stays off so a long clone cannot bury real
            # configuration diagnostics under megabytes of progress output.
            FetchContent_Declare(${D_NAME}
                GIT_REPOSITORY "${D_GIT_REPOSITORY}"
                GIT_TAG        "${D_GIT_TAG}"
                GIT_SHALLOW    TRUE
                GIT_PROGRESS   FALSE
                ${_extra_opts})
        endif()

        FetchContent_MakeAvailable(${D_NAME})
        set(_root "${${_lower}_SOURCE_DIR}")

    elseif(D_MODE STREQUAL "vendored")
        if(NOT D_PATH)
            set(D_PATH "${D_NAME}")
        endif()
        set(_root "${NX_THIRD_PARTY_DIR}/${D_PATH}")
        if(NOT IS_DIRECTORY "${_root}")
            set(_found FALSE)
        endif()

    elseif(D_MODE STREQUAL "system")
        if(D_PACKAGE)
            find_package(${D_PACKAGE} QUIET)
            if(NOT ${D_PACKAGE}_FOUND)
                set(_found FALSE)
            endif()
        endif()

    else()
        message(FATAL_ERROR "nx_dependency(${D_NAME}): unknown MODE '${D_MODE}'")
    endif()

    if(NOT _found)
        if(D_REQUIRED)
            message(FATAL_ERROR "nx_dependency(${D_NAME}): required dependency not found")
        endif()
        message(STATUS "nx: dependency '${D_NAME}' unavailable (mode=${D_MODE})")
        set(NX_DEP_${D_NAME}_FOUND FALSE PARENT_SCOPE)
        return()
    endif()

    # Include directories: the fetched/vendored root plus any requested
    # subdirectories (a library's public headers often live under include/).
    set(_includes "")
    if(_root)
        list(APPEND _includes "${_root}")
        foreach(_sub IN LISTS D_INCLUDE_SUBDIRS)
            list(APPEND _includes "${_root}/${_sub}")
        endforeach()
    endif()
    list(APPEND _includes ${D_LIBRARIES_INCLUDE_DIRS})

    # Some header-only dependencies bundle further third-party code that has to
    # be compiled separately (tinyexr ships miniz). Collect those into a small
    # static library so consumers only link one thing.
    set(_extra_targets "")
    if(D_SOURCES)
        set(_src_files "")
        foreach(_src IN LISTS D_SOURCES)
            if(_root)
                list(APPEND _src_files "${_root}/${_src}")
            else()
                list(APPEND _src_files "${_src}")
            endif()
        endforeach()

        add_library(${_real}_bundled STATIC ${_src_files})
        set_target_properties(${_real}_bundled PROPERTIES
            POSITION_INDEPENDENT_CODE ON
            ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_ARCHIVE_OUTPUT_DIRECTORY}")
        # Third-party sources are not held to nyx's warning standards; their
        # warnings would otherwise drown out the ones that matter.
        target_compile_options(${_real}_bundled PRIVATE -w)
        if(_includes)
            target_include_directories(${_real}_bundled PUBLIC ${_includes})
        endif()
        if(D_DEFINITIONS)
            target_compile_definitions(${_real}_bundled PUBLIC ${D_DEFINITIONS})
        endif()
        list(APPEND _extra_targets ${_real}_bundled)
    endif()

    add_library(${_real} INTERFACE)
    add_library(${_alias} ALIAS ${_real})
    if(_includes)
        target_include_directories(${_real} INTERFACE ${_includes})
    endif()
    if(D_DEFINITIONS)
        target_compile_definitions(${_real} INTERFACE ${D_DEFINITIONS})
    endif()
    if(_extra_targets OR D_LIBRARIES)
        target_link_libraries(${_real} INTERFACE ${_extra_targets} ${D_LIBRARIES})
    endif()

    message(STATUS "nx: dependency '${D_NAME}' ready (mode=${D_MODE})")
    set(NX_DEP_${D_NAME}_FOUND TRUE PARENT_SCOPE)
endfunction()
