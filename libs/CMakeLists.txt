# Reusable code shared by experiments.
#
# Every library exposes a namespaced alias so experiments link by intent:
#   nx::io       linear HDR image input/output
#   nx::metrics  image quality metrics
#   nx::profile  timing, GPU counters and benchmark reports
add_subdirectory(io)
add_subdirectory(profile)
add_subdirectory(metrics)
