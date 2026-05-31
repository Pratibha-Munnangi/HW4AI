# CF09 CLLM — Roofline Analysis
**Path:** `codefest/cf09/benchmarks/roofline_analysis.md`

The M3 V5 accelerator point on the roofline (0.221 GFLOP/s, **PROJECTED**)
sits **4.8× below the compute ceiling** of 1.07 GFLOPS at the FP32
perfect-reuse AI of 5.33 FLOP/B. The kernel is structurally
compute-bound (AI well right of the 2.00 FLOP/B ridge), so the gap is
a utilization shortfall, not a bandwidth one. Because the V5 number
was extrapolated linearly from a D=4 scope-reduced tb_top measurement
to the full M1 workload (2,048 invocations × 9,255 ns), the dominant
uncertainty in the projection is **whether per-invocation runtime
remains constant** when the d-dim extends from 4 to 16. The M4 P-acc
backlog item (engine-internal D-chaining) is expected to amortize
per-tile load/drain overhead, making 18.95 ms a pessimistic upper
bound. Converting projected → measured requires running tb_top with a
multi-d-block driver (or post-P-acc RTL) end-to-end and recording the
actual wall-clock. (147 words)
