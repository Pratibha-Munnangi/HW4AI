# CF09 — Roofline Analysis for the QKᵀ Accelerator
**ECE 410/510: Hardware for AI and ML, Spring 2026**
**Codefest 09 — CMAN Component**
**Path:** `codefest/cf09/cman_ai_analysis.md`

---

## Summary

This analysis applies the roofline model to my **QKᵀ chiplet as actually
synthesized in M3 (V5)**, not the M1 projection. The synthesized design is
a 4×4 FP16-multiply / FP32-accumulate systolic array on sky130, closing
timing at 33.3 MHz on the typical PVT corner. Two arithmetic-intensity
bounds (no-reuse lower bound and perfect-reuse upper bound) are computed
for the QKᵀ kernel at the M1 operating point. The bounds bracket where
the design can sit on the roofline given the reuse pattern its tiling
scheme actually achieves. The M1 software baseline and the M4 projected
post-pipelining numbers are overlaid for comparison.

---

## Task 1 — Dominant kernel

**Kernel:** QKᵀ scaled dot-product score computation for transformer
self-attention.

$$
\text{scores}[b,h,i,j] = \frac{1}{\sqrt{d_{\text{head}}}} \sum_{k=0}^{d_{\text{head}}-1} Q[b,h,i,k] \cdot K[b,h,j,k]
$$

This is a batched, multi-head **dense GEMM**.

**Kernel operating point** (matches the M1 software baseline so the
hardware and software numbers are directly comparable):

| Symbol | Meaning | Value |
|---|---|---|
| B | batch size | 8 |
| H | number of heads | 4 |
| T | sequence length | 64 |
| d_head | per-head dimension | 16 |

**Hardware realization (M3 V5 synthesis actuals):**

| Parameter | Value |
|---|---|
| Compute engine | 4×4 output-stationary systolic array (16 PEs) |
| PE arithmetic | FP16 multiplier + FP32 accumulator |
| Closed clock (nom_tt) | 33.3 MHz (30 ns period, +9.06 ns slack) |
| External interface | 128-bit AXI4-Stream @ 33.3 MHz |
| Process | sky130_fd_sc_hd, OpenLane 2 GDS-clean signoff |
| Area | 315,688 µm² (~0.32 mm²) |
| Power @ nom_tt | 162.2 mW (OpenSTA estimate) |

**Dominance evidence:** From M1 cProfile, `qkt_kernel()` consumed 91% of
software runtime (0.010 s of 0.011 s over 10 runs). This is the kernel
the accelerator was designed to offload.

**Datatypes for AI calculation:**

- **M1 software baseline:** FP64 (NumPy default) → 8 bytes/element
- **M3 V5 hardware:** FP32 accumulator path → 4 bytes/element

AI is byte-width dependent; both datatypes are reported below so the M1
overlay on the roofline uses the bytes M1 actually moved (FP64) and the
M3 point uses the bytes the hardware actually moves (FP32).

---

## Task 2 — Total FLOPs per kernel invocation

For dense GEMM, each output element of `scores[b,h,i,j]` requires
d_head multiplies + (d_head − 1) adds ≈ **2 · d_head FLOPs** per element.

$$
\text{FLOPs} = 2 \cdot B \cdot H \cdot T^2 \cdot d_{\text{head}}
            = 2 \cdot 8 \cdot 4 \cdot 64^2 \cdot 16
            = \mathbf{4{,}194{,}304 \ \text{FLOPs}} \approx 4.19 \text{ MFLOPs}
$$

Equivalently: **2,097,152 MACs** per invocation. The FLOP count is
datatype-independent — same number whether the operands are FP32 or FP64.

---

## Task 3 — Bytes transferred and arithmetic-intensity bounds

The QKᵀ kernel follows the **classic GEMM operand-reuse pattern**: each
element of Q is reused T=64 times (multiplied against every column of
Kᵀ), each element of K is reused T=64 times (against every row of Q),
and each output element accumulates d_head=16 partial products before
being written once. The accelerator's job is to capture as much of this
reuse on-chip as possible.

**Operand counts (fixed by the math):**

| Tensor | Shape | Elements |
|---|---|---|
| Q | (B, H, T, d_head) | 32,768 |
| K | (B, H, T, d_head) | 32,768 |
| scores (output) | (B, H, T, T) | 131,072 |
| Total | — | 196,608 |
| MACs performed | — | 2,097,152 |

### Upper-bound AI — perfect on-chip reuse (loaded-once)

**Reuse pattern named:** GEMM operand reuse with each input tensor
loaded from off-chip exactly once and held in on-chip SRAM. Output is
written once. This is the upper bound: it is what a perfectly
tiled/buffered implementation achieves.

$$
\text{Bytes}_{\text{perfect}} = (|Q| + |K| + |\text{scores}|) \times \text{bytes\_per\_elem}
$$

| Datatype | Bytes/elem | Total bytes | AI = FLOPs / Bytes |
|---|---|---|---|
| FP64 (M1 sw) | 8 | 196,608 × 8 = 1,572,864 B (1.50 MB) | **2.667 FLOP/B** |
| FP32 (M3 hw) | 4 | 196,608 × 4 = 786,432 B (0.75 MB) | **5.333 FLOP/B** |

*Sanity check:* the FP64 number matches my CF02 `ai_calculation.md`
result of 2.667 FLOP/B exactly. ✓ Halving the byte width doubles AI as
expected. ✓

### Lower-bound AI — no data reuse

Worst-case streaming: every MAC re-fetches both operands from off-chip,
and the output is written once.

$$
\text{Bytes}_{\text{no-reuse}} = (2 \cdot \text{MACs} + |\text{scores}|) \times \text{bytes\_per\_elem}
$$

$$
= (2 \cdot 2{,}097{,}152 + 131{,}072) \times \text{bytes\_per\_elem}
= 4{,}325{,}376 \times \text{bytes\_per\_elem}
$$

| Datatype | Bytes/elem | Total bytes | AI = FLOPs / Bytes |
|---|---|---|---|
| FP64 | 8 | 34,603,008 B (33.0 MB) | **0.1212 FLOP/B** |
| FP32 | 4 | 17,301,504 B (16.5 MB) | **0.2424 FLOP/B** |

*Sanity check:* the no-reuse limit asymptotes toward 2 FLOPs / (2 ·
bytes_per_elem) = 0.125 (FP64) / 0.25 (FP32). The small offset arises
from the once-only output writes. ✓

### AI summary

| Datatype | AI lower (no reuse) | AI upper (perfect reuse) | Spread |
|---|---|---|---|
| FP64 (M1 sw baseline) | 0.121 FLOP/B | 2.667 FLOP/B | 22× |
| FP32 (M3 V5 hardware) | 0.242 FLOP/B | 5.333 FLOP/B | 22× |

The **22× spread between the two bounds** is what makes the on-chip
buffering strategy the central design lever for this kernel: at the
upper bound the kernel is compute-bound on every platform considered;
at the lower bound it is deeply memory-bound on every platform.

---

## Task 4 — Roofline construction (three platforms)

### Platform ceilings

**M1 software (Intel i5-1235U laptop, from CF02):**
- Peak compute: P_M1 = **176.0 GFLOP/s** (FP64, 2 P-cores AVX2 @ 4.4 GHz
  + 8 E-cores AVX2 @ 3.3 GHz)
- Peak BW: B_M1 = **76.8 GB/s** (LPDDR5-5200, dual-channel)
- Ridge: I*_M1 = P/B = **2.29 FLOP/B**

**M3 V5 synthesized (sky130, this project, post-PnR):**
- Peak compute: P_M3 = 16 PEs × 2 FLOPs/cycle × 33.3 MHz =
  **1.067 GFLOPS**
- Peak BW: B_M3 = 128 bits × 33.3 MHz / 8 = **0.533 GB/s**
- Ridge: I*_M3 = **2.00 FLOP/B**

**M4 projected (sky130 with adder pipelining, P-top backlog item):**
- Peak compute: P_M4 = 16 PEs × 2 × 100 MHz = **3.20 GFLOPS**
- Peak BW: B_M4 = 128 bits × 100 MHz / 8 = **1.60 GB/s**
- Ridge: I*_M4 = **2.00 FLOP/B**

Note that M3 and M4 share the same ridge — clock scaling shifts the
roofline along the constant-ridge diagonal, lifting the compute ceiling
without re-balancing compute vs bandwidth.

### Kernel positions on each roofline

| Platform | AI (perfect reuse) | Ridge | Bound | Attainable |
|---|---|---|---|---|
| M1 sw (FP64) | 2.67 FLOP/B | 2.29 | Compute-bound | 176 GFLOP/s |
| M3 V5 (FP32) | 5.33 FLOP/B | 2.00 | Compute-bound | **1.07 GFLOPS** |
| M4 proj (FP32) | 5.33 FLOP/B | 2.00 | Compute-bound | **3.20 GFLOPS** |

| Platform | AI (no reuse) | Bound | Attainable |
|---|---|---|---|
| M1 sw (FP64) | 0.121 FLOP/B | Memory-bound | 9.3 GFLOP/s |
| M3 V5 (FP32) | 0.242 FLOP/B | Memory-bound | **0.129 GFLOPS** |
| M4 proj (FP32) | 0.242 FLOP/B | Memory-bound | **0.388 GFLOPS** |

### Plot

See `cman_roofline_sketch.png` / `.pdf`. All three rooflines are drawn
in log–log with peak BW and peak compute ceilings; both AI bounds for
the QKᵀ kernel are shown as vertical guides; ridge points are marked on
M1 and M3 (M4 shares M3's ridge by construction). The M3 V5 attainable
performance is plotted at both AI bounds to make the memory-bound vs
compute-bound regimes explicit. The M1 software measured throughput
(4.16 GFLOP/s, 2.4% of attainable) is shown on the M1 roofline for
context. The M4 roofline is dashed and faded to distinguish projection
from synthesized fact.

---

## Task 5 — Bottleneck and highest-leverage change

### Is the current design memory-bound, on-chip-bandwidth-bound, or
### compute-bound?

The M3 V5 design is **compute-bound at the perfect-reuse AI upper bound
of 5.33 FLOP/B** (well above the ridge of 2.00 FLOP/B). The peak
attainable is **1.07 GFLOPS**, set by the 16-PE × 33.3 MHz throughput
of the array, *not* by the AXI4-Stream interface and *not* by on-chip
SRAM bandwidth (internal Q/K-buffer BW exceeds AXI BW by orders of
magnitude — on-chip is not the binding constraint).

The binding physical constraint is documented in
`project/m3/synth/critical_path.md`: the FP32 adder has **~58 levels of
combinational logic** post-tech-map, dominated by two variable barrel
shifters (24-bit mantissa right-shift for alignment before add, 24-bit
left-shift for normalization after add). This logic depth forces the
30 ns clock period at the typical PVT corner; at the slow-slow corner
(`nom_ss_100C_1v60`) the same path takes ~41 ns and busts setup by
~12 ns, confirming the adder as the slack-determining structure.

**Caveat on effective AI vs upper-bound AI.** The M3 V5 tiling scheme
includes a documented scope reduction to D = 4 inner-dim per tile
(`synthesis_notes.md`, §"Scope adjustments"). This breaks full d-dim
reuse — Q and K are re-streamed across the 16 tile passes that compose
the 16×16 result, so the *effective* AI sits below the 5.33 FLOP/B
upper bound, somewhere in the range 1.5–2.5 FLOP/B (close to the
ridge). The design therefore lives near the knee of the roofline, not
firmly in the compute-bound region. This matters for Task-5b: a fix
that only lifts the compute ceiling will be partially wasted unless
the reuse pattern is also restored.

### Single highest-leverage change

A **pair** of M4 changes, applied together:

**1. Pipeline the FP32 adder internally** (`synth/critical_path.md`
backlog item P-top). Insert two pipeline registers inside
`fp32_adder.sv` — one after the exponent compare + right-shift
alignment, one after the mantissa add + leading-zero count + left-shift
normalization. This splits the 58-level path into three balanced
~20-level stages, targeting **100–125 MHz post-PnR**. Cost: ~64 new
flops per PE × 16 PEs ≈ 1024 additional flops, plus a +2 bump in
ARRAY_LAT. **Expected payoff: 3–4× peak compute** (1.07 → ~3.2–4.3
GFLOPS).

**2. Restore full d-dim accumulation** (eliminate the M3 D = 4 scope
reduction). Either chain D-blocks inside the engine's `S_COMPUTE` state
or accumulate across d-blocks on the host. **Expected payoff: restores
effective AI from ~1.5–2.5 toward the 5.33 FLOP/B upper bound**, so the
adder-pipeline unlock actually translates into attained throughput
instead of being memory-throttled.

**Why this pairing, ranked first:** change (1) attacks the named
critical path identified by post-PnR STA, with bounded effort and known
ROI. Change (2) ensures the gain isn't dissipated by re-streaming
operands. Together they lift the M3 V5 design to its M4 projected
position on the roofline (≈3.2 GFLOPS, compute-bound at upper-bound
AI), bringing the chiplet within ~75% of the M1 software measured
baseline (4.16 GFLOP/s on i5-1235U) at 0.32 mm² and 162 mW — orders of
magnitude better per-mm² and per-Watt than the CPU comparison point.

### Caveat: roofline ceiling vs measured utilization

The analysis above identifies the **roofline ceiling** the M3 V5 design
can attain. A separate question is what fraction of that ceiling the
design actually reaches in simulation. tb_top end-to-end runtime is
9,255 ns (V5, from `synthesis_notes.md`). A back-of-the-envelope
*compute-only* floor for the 16×16 result is ≈ 16 tiles × 4 inner-dim
cycles + drain ≈ 80 cycles × 30 ns = 2,400 ns of useful array work,
which implies the remaining ~6,800 ns is some mix of AXI4-Lite control
transactions, AXI4-Stream load/drain phases, FSM state transitions,
and testbench host overhead. **This breakdown has not been measured
from the V5 tb_top waveform** and is therefore not factored into the
roofline plot above; the plot reflects peak attainable, not measured
utilization.

This matters for M4 because if a significant share of the 6,800 ns is
*real accelerator stall time* (engine idle waiting on AXI loads, as
opposed to host/testbench latency that wouldn't exist in a deployed
system), then the highest-leverage M4 change may shift from "lift the
compute ceiling via adder pipelining" to "lift the realized
utilization via streaming/double-buffer enhancements" — closer in
spirit to a classic AXI bus-overhead optimization. The two are not
mutually exclusive: pipelining the adder still helps even at low
utilization, but its payoff is amplified by also closing the
utilization gap. **Measuring the V5 stall vs work breakdown from
tb_top waveforms is itself an M4 task**, and the result will determine
how the M4 design-justification report ranks adder pipelining against
interface/streaming improvements in the final priority order.

**What is explicitly *not* on the M4 critical path:**

- **Adder carry-select / carry-lookahead rewrite** — would save 5–10
  levels in the 24-bit adder portion of the path, but the barrel
  shifters (not the carry chain) dominate. Lower ROI than pipelining.
  Marked M5+ in `critical_path.md`.
- **Scaling the array (4×4 → 8×8 or larger)** — would raise peak
  compute proportionally, but pushes the ridge to the right (e.g.,
  8.0 FLOP/B for an 8×8 array at the same AXI width), crossing into
  the memory-bound regime where the AI upper bound of 5.33 no longer
  saturates compute. This is a *future* lever, not an M4 one, and
  would also require widening AXI.
- **Lowering accumulator precision (FP32 → FP16/BF16 add)** —
  attractive in principle (halves mantissa-shift depth, ~2× fmax gain,
  smaller area), but introduces a numerical-precision deviation from
  the M1 reference and would require re-verifying tb_top against a new
  bit-exact reference. Documented as a precision-tradeoff option in
  the M4 report's "what did not work / future variants" section, not
  in the critical M4 path.

---

## Deliverables

| File | Description |
|---|---|
| `cman_ai_analysis.md` | This document (Tasks 1–5 writeup) |
| `cman_roofline_sketch.pdf` | Roofline plot, three platforms, both AI bounds (required deliverable) |
| `cman_roofline_sketch.png` | Same plot, PNG for inline viewing |
| `make_roofline.py` | Source script for the plot (numbers reproducible from this) |

## References to prior project artifacts

- M1: `project/m1/sw_baseline.md` — i5-1235U benchmark (4.16 GFLOP/s
  measured, 176 GFLOP/s attainable, AI = 2.67 FLOP/B FP64)
- CF02: `codefest/cf02/analysis/ai_calculation.md` — original FP64 AI
  derivation
- M3: `project/m3/synth/synthesis_notes.md` — V5 post-PnR numbers
  (33.3 MHz, 0.32 mm², 162 mW, sky130)
- M3: `project/m3/synth/critical_path.md` — fp32_adder 58-level path,
  P-top backlog item for M4 pipelining
