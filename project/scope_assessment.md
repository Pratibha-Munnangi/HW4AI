# Project Scope Assessment — Updated post-CF07

**Project:** QKT attention accelerator — systolic FP16 MAC array, FPGA SoC host, AXI4-Lite + AXI4-Stream interface (`qkt_interface`).
**Update trigger:** CF07 OpenLane 2.3.1 synthesis of `compute_core`.

## Synthesis-grounded findings

CF07 synthesized `compute_core` at N=4 (16 PEs) on sky130A. Setup WNS = −61.51 ns (slow corner) / −27.16 ns (typical) at the 2.0 ns / 500 MHz target; total cell area = 298,002 µm², 93.6% combinational. The binding constraint is the per-PE critical path: an unpipelined FP16 multiply followed by a full FP32 add within one cycle. Hold timing and synthesis structural checks are clean — 0 inferred latches, 0 reported problems.

## Scope decision

Scope is adjusted, not abandoned. The systolic-array architecture and the FP16/FP32 datapath are confirmed sound — synthesis elaborated cleanly with correct PE counts (896 flip-flops = 16 × 56 bits). What changes is the timing target: 500 MHz is not achievable with an unpipelined PE. For M3 I will pipeline the PE (per `m3_plan.md`) and either reach 500 MHz with two pipeline stages or retarget to the achievable frequency. Array size remains N=4 for M3; scaling to a larger array is deferred until the pipelined PE closes timing.

## Rationale

The −61.51 ns WNS is a structural result, not a tuning problem — it directly reflects two full floating-point units chained in a single cycle. Pipelining is the correct, scoped response and keeps the project deliverable on schedule for M3. The FP16/FP32 datapath is confirmed as the current design, since `fp16_multiplier` and `fp32_adder` are the synthesized arithmetic blocks.
