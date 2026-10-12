# nx::io — linear HDR image input/output.
#
# tinyexr goes through nx_dependency() so the pinned revision lives in exactly
# one place. It ships miniz, which is compiled into a small bundled static
# library rather than being exposed to consumers.

nx_dependency(
    NAME           tinyexr
    MODE           fetchcontent
    URL            https://github.com/syoyo/tinyexr/archive/refs/tags/v1.0.13.tar.gz
    URL_HASH       SHA256=01edf1e18e32e5503fdd2a35d62bb593109daa392324cec0157b150e5fd68077
    SKIP_CMAKE
    SOURCES        deps/miniz/miniz.c
    INCLUDE_SUBDIRS deps/miniz
    DEFINITIONS    TINYEXR_USE_MINIZ=1
    REQUIRED)

add_library(nx_io STATIC src/exr.cpp)
add_library(nx::io ALIAS nx_io)

nx_target_defaults(nx_io)
target_include_directories(nx_io PUBLIC include)
target_link_libraries(nx_io PRIVATE nx::dep::tinyexr)
