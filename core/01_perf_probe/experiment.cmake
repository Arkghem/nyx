# Performance probe — reference implementation of the benchmark contract.
#
# Every benchmarkable experiment follows this shape: run warm-up frames, then
# measure N frames, then write a JSON report to reports/bench/. scripts/bench.sh
# drives it through the --bench-* flags, scripts/perf_gate.py compares the result
# against reports/baselines/.
#
# On this machine GPU time comes from MTLCommandBuffer.GPUStartTime/GPUEndTime,
# because compute encoders cannot be sampled with MTLCounterSampleBuffer here.

nx_experiment(
    NAME    01_perf_probe
    TYPE    native
    DEPS    metal
    SOURCES src/main.mm
    SHADERS shaders/work.metal
    LINK    nx::io nx::profile
)
