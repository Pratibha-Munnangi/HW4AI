# Remaining Tasks Before M4 Submission
**Path:** `project/remaining_tasks.md`

Three specific changes required between M3 V5 (current state) and M4
submission, in order of expected throughput impact. Each is traceable
to a named M3 deliverable (synthesis report, critical-path analysis,
or benchmark gap).

---

## Task 1 — Pipeline `fp32_adder.sv` with two internal registers (P-top)

**What:** Insert pipeline registers at two cut points inside
`rtl/fp32_adder.sv`: (a) after the exponent-compare + mantissa
right-shift alignment stage, (b) after the 24-bit mantissa add +
leading-zero count + left-shift normalize stage. This splits the
current 58-level combinational path into three balanced
~20-level stages.

**Why:** Post-PnR STA (`project/m3/synth/critical_path.md`) names the
fp32_adder's variable barrel shifters as the binding setup constraint
on `nom_tt_025C_1v80`. At 30 ns, slack is +9.06 ns; at 8–10 ns the
same RTL would close. Without this fix, V5 cannot achieve the M4
target of 100–125 MHz.

**Acceptance:** post-PnR setup WNS positive at a 8–10 ns clock target
on `nom_tt_025C_1v80`; `tb_top` still passes 256/256 with the bumped
ARRAY_LAT (+2 cycles). Cost: ~1024 additional flops project-wide.

---

## Task 2 — Add d-dim chaining to top.sv S_COMPUTE (P-acc)

**What:** Extend the `top.sv` tile-sequencer FSM with a `d_block_idx`
register that iterates 0 → 3 across four D=4 inner-dim blocks per
spatial tile, with `core_clear` deasserted between d-blocks so
`core_pe.acc_out` accumulates across the full d_head=16. Re-route the
AXI4-Stream Q/K input addressing so each d-block fetches its
corresponding 4-of-16 slice of d-dim values.

**Why:** V5 only accumulates 4 of 16 d-values per tile (M3 scope
reduction documented in `project/m3/synth/synthesis_notes.md`,
§"Scope adjustments"). This breaks GEMM operand reuse — Q and K must
be re-streamed across multiple invocations to compose a complete
QKᵀ result, dragging effective AI well below the 5.33 FLOP/B upper
bound. Restoring in-engine d-chaining keeps Q and K resident in the
on-chip buffers across all four d-blocks, recovering full reuse in a
single START.

**Acceptance:** one START produces a 16×16 QKᵀ result with all
d=0..15 accumulated, bit-identical to the M1 NumPy reference at
d_head=16; no host-side d-dim accumulation required.

---

## Task 3 — Replace projected M4 benchmark with measured wall-clock

**What:** Run `tb_top` end-to-end post-Task-1 and post-Task-2,
covering the full M1 workload (B=8, H=4, T=64, d_head=16) either as
a single multi-head-tile sweep or as a representative sub-workload
with documented extrapolation. Record runtime, update
`codefest/cf09/benchmarks/benchmark_results.md` to replace the
"M4 projected peak" row with **"M4 measured (post-Task-1 + Task-2)"**
including the actual cycle count from `final_run.log`. Also generate
SAIF activity-factor data from this run and re-do the OpenSTA power
estimate so the energy number in `benchmark_results.md` reflects
benchmark-driven switching activity instead of OpenLane defaults.

**Why:** The M4 spec's "Not Yet" list explicitly flags rooflines and
benchmark numbers that use projected values without explanation. The
roofline plot in `project/m4/bench/roofline_final.png` is required
to show the **measured** accelerator point, not the projection.
Without this task, the CF09 projected number propagates into M4 and
becomes a Not Yet criterion.

**Acceptance:** `roofline_final.png` shows an accelerator point
labeled "measured," and every speedup number in `benchmark.md`
traces to a `benchmark_data.csv` row whose method column reads
`measured`, not `projected`.

---

## Out of scope for M4 (deferred)

For completeness, the M3 synthesis notes identify additional backlog
items that are *not* included above and are explicitly deferred:

- SS-corner setup closure (downstream of Task 1; the same pipelining
  fix should bring SS WNS positive but no separate work item required)
- Carry-select rewrite of the 24-bit mantissa adder
  (`project/m3/synth/critical_path.md` ranks this as "modest ROI"
  vs Task 1's structural pipelining)
- Array scale-up beyond 4×4 (out of scope per `project/m1/
  partition_rationale.md`; would also require AXI4-Stream widening)
- Multi-tile stress test in `tb_compute_core` and directed-stimulus
  `tb_fp32_adder` (DV-side; M2 backlog, useful but not throughput-impacting)
