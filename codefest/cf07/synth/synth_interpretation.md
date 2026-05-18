# CF07 — OpenLane 2 Synthesis Interpretation

**Course:** ECE 410/510 — Hardware for AI/ML · Codefest cf07
**Target:** Option A — QKT compute core. `synth_top.sv`, top module `compute_core`, N=4 (4×4 = 16 `core_pe` instances).
**Flow:** OpenLane 2.3.1 — Yosys synthesis + OpenROAD STA (pre-PnR), PDK sky130A.

## (a) Clock period and worst-case slack

Synthesis ran at a clock period of **2.0 ns (500 MHz target)**. The design misses this target by a wide margin. Worst-case setup slack is **WNS = −61.51 ns** at the slow corner (ss_100C_1v60); at the typical corner (tt_025C_1v80) WNS = −27.16 ns with total negative slack TNS = −13,102 ns across hundreds of failing endpoints. A −61.51 ns violation on a 2.0 ns clock means the critical path actually needs roughly 63 ns to settle — about 31× the budget. Hold timing is clean: hold WNS = 0 and hold TNS = 0 at every corner.

## (b) Critical path

The worst path runs from startpoint `_61130_` to endpoint `_61171_`, both rising-edge flip-flops clocked by `clk` (data arrival 62.97 ns vs. 1.46 ns required). These are synthesized register names inside one `core_pe`: the path is the accumulator feedback loop `acc_out → fp32_adder` combined with `fp16_multiplier → fp32_adder`. The dominant cells along it are sky130 combinational gates implementing the floating-point datapath — the 11×11 mantissa multiply in `fp16_multiplier`, then the FP32 adder's alignment shifter, the 27-way leading-zero priority encoder, and the variable normalization shifter. The structural cause is that each `core_pe` performs a full FP16 multiply **and** a full FP32 add within a single cycle, with no register between `u_mul` and `u_add`.

## (c) Total cell area and top three contributors

Total cell area is **298,002 µm²**, of which only **6.40% (19,058 µm²) is sequential** — the design is 93.6% combinational logic. Total cell count is **31,067**. Top three contributors: (1) the FP-arithmetic logic gates — 2,877 `nand2`, 2,547 `nor2`, and 1,997 `mux2`, which dominate area; (2) the 2,739 `xor2`/`xnor2` gates, the signature of the FP mantissa multiply and the adder's normalization logic; (3) the 896 `dfxtp` flip-flops (16 PEs × 56 bits = 32-bit accumulator + 16-bit `a_out` + 16-bit `b_out`). The 16 PEs' FP units, not control logic, drive the area.

## (d) Failed constraints, hold violations, warnings

Setup is the dominant problem: WNS −61.51 ns / TNS −13,102 ns, with hundreds of failing PE endpoints. Hold timing is fully clean (0 violations). Yosys checks are clean — `chk.rpt` reports 0 problems and `latch.rpt` shows no inferred latches anywhere. Only benign warnings appear: unused parameter `D` in `compute_core`, a width-expand on `exp_fp32` in `fp16_multiplier`, and unused bits `norm_sig[27:26]` in `fp32_adder`. Two flow notes: `PNR_SDC_FILE` was not defined so a generic SDC fallback was used, and a smaller secondary violator group (`rst → _603xx_`, −10.52 ns) shows the reset fanout also fails setup. The single most important finding: every PE endpoint fails setup by tens of nanoseconds because the multiply-and-add is unpipelined — that is the one problem M3 must fix.
