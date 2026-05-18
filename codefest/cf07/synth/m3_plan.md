# CF07 — M3 Synthesis Plan

**For M3 (due May 24).** Synthesized Option A: the QKT `compute_core` at N=4 (16 PEs).

**Pipeline the PE critical path.** Synthesis gave setup WNS = −61.51 ns (slow corner) and −27.16 ns (typical) at a 2.0 ns target, with the worst path (`_61130_` → `_61171_`) running `fp16_multiplier` then `fp32_adder` unregistered inside each `core_pe`. For M3 I will insert a pipeline register on `product_fp32` between `u_mul` and `u_add`, splitting the path into a multiply stage and an add/accumulate stage. Because the measured arrival time is ~63 ns, one cut alone will not close timing, so I will add a second register inside the FP32 adder (after the alignment stage) if a re-run still shows negative slack.

**Clock target.** The 500 MHz (2.0 ns) goal is unrealistic for an unpipelined FP datapath — missed by 27–61 ns. For M3 I will pipeline toward 500 MHz but report the achieved frequency honestly; if two stages are insufficient I will retarget the clock to the frequency implied by the achieved post-pipeline path delay.

**Precision / scope.** FP arithmetic drives 93.6% of the 298,002 µm² area. I will keep FP16/FP32 for M3, with INT8/INT32 noted as a fallback only if timing or area remain infeasible after pipelining.

**M3 deliverable:** re-synthesize the pipelined core and report the new WNS against the same 2.0 ns target.
