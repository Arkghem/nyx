# nx::profile — timing, GPU counter sampling and benchmark reports.
#
# Produces the JSON that scripts/perf_gate.py compares against
# reports/baselines/.

add_library(nx_profile STATIC
    src/perf_report.cpp
    src/gpu_timer.mm)

add_library(nx::profile ALIAS nx_profile)

nx_target_defaults(nx_profile)
target_include_directories(nx_profile PUBLIC include)
# Private: no public header of nx::profile exposes nx::io types, so consumers
# should not inherit the EXR reader.
target_link_libraries(nx_profile PRIVATE nx::io "-framework Metal" "-framework Foundation")
