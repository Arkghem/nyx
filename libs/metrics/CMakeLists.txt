# nx::metrics — image quality metrics.
#
# Deliberately limited to metrics whose definition leaves no room for
# interpretation (PSNR, MAE, maximum absolute error, difference images).
# SSIM and FLIP are computed in Python on purpose: they exist in several
# subtly different flavours and nyx wants exactly one implementation of each,
# so the reported number is comparable across stages and machines.

add_library(nx_metrics STATIC src/metrics.cpp)
add_library(nx::metrics ALIAS nx_metrics)

nx_target_defaults(nx_metrics)
target_include_directories(nx_metrics PUBLIC include)
target_link_libraries(nx_metrics PUBLIC nx::io)
