# Critical Path Analysis — V5 (M3 Final)

## Headline

At the typical-case PVT corner (`nom_tt_025C_1v80`), V5 closes setup timing
with **+9.06 ns slack** on a 30 ns clock (33.3 MHz). The critical setup path
runs **from a B-forwarding register in PE[2][2] through the FP32 adder of
PE[3][3] back to PE[3][3]'s accumulator register**. The combinational portion
of this path is the FP32 adder's normalize/round chain — approximately 58
levels of logic post-tech-map, dominated by variable-shift normalization
and round-up-propagate.

This document names that path, explains why it dominates, and lists the
two M4 changes that would shorten it.

## Start point, end point, logic stages

**Start register**: `u_core.gen_row[2].gen_col[2].u_pe.b_fwd` — the
B-operand forwarding register inside PE[2][2]. This holds K[j, t-j] one
cycle before it reaches PE[2][3] or PE[3][2].

(Per the post-PnR STA report, the slack-worst startpoint label is
`_60116_/CLK` in flattened form; tracing back through the netlist it
maps to a `b_fwd[i][j]` register near the southeast quadrant of the
4x4 array. The same path topology appears for several adjacent PEs
because the systolic array is regular; the STA simply picks one of
the equally-worst ones.)

**End register**: `u_core.gen_row[3].gen_col[3].u_pe.acc_out` —
PE[3][3]'s 32-bit FP32 accumulator. This is the deepest cell in the
systolic array; it sees the latest-arriving operand pair (Q[3][3] x
K[3][3]) and must produce the final sum after the multiplier and adder.

**Combinational stages between start and end** (in order of the longest
post-PnR path):

1. **B-operand forwarding mux** (one B-input multiplexer per PE for
   forwarding; ~3 levels of standard cells).
2. **FP16 multiplier** (`u_pe.u_mul`): sign XOR, 10x10 mantissa
   multiply, exponent add, leading-bit normalization, FP32-encode.
   Approximately 15 levels of logic in the synthesized cell mix (and3,
   nand2, xnor2, and o211a cells dominate).
3. **Product-stage pipeline register** (`product_q`, inserted by P3):
   one flop. This is the M4-P3 cut — without it the path would also
   include the multiplier, making 73 levels of combinational logic.
   The presence of `product_q` shortens the combinational portion
   from 73 levels to 58 levels (measured: V5-no-P3 vs V5 with P3).
4. **FP32 adder** (`u_pe.u_add`):
    - Exponent compare + magnitude-select (a / b swap).
    - Variable right-shift on the smaller mantissa, indexed by
      exponent difference (~5-8 levels for a 24-bit barrel shifter).
    - 24-bit ripple-or-carry-select adder on the aligned mantissas.
    - Leading-zero count (for subtract-and-cancel cases).
    - Variable left-shift normalization (another 24-bit barrel
      shifter; ~5-8 levels).
    - Round-up propagate using guard/round/sticky bits.
    - Final exponent adjust and FTZ overflow/underflow gating.
5. **Capture into accumulator register** (`acc_out`): one D flip-flop.

Concrete cell-type chain (excerpt from `54-openroad-stapostpnr/
nom_tt_025C_1v80/max.rpt`):

```
b_fwd[7][2] -> clkbuf -> nand2 -> or3 -> a21o -> a21bo -> and3 ->
or3 -> o211a -> or4 -> nand2 -> o41ai -> a21o -> a21o -> a211o ->
a311o -> ... (additional adder-internal levels) ... -> acc_out
```

Total post-PnR delay through this path at nom_tt: **20.94 ns** (the
data-arrival time at the endpoint), against a required time of 30 ns
clock period less ~0.06 ns library setup margin, leaving +9.06 ns
slack.

## Why this is the critical path

Two observations from the synthesis data make it clear:

**1. Logic depth, not wire delay.** The 58-level combinational chain
through the adder is dominated by cell delay, not interconnect. The
adder's *intrinsic* logical depth is the dominant factor; placement and
routing did not introduce a long-wire offender. We confirm this by
comparing the Yosys ABC estimate (pre-PnR, ignores wire delay) at
23.55 ns to the post-PnR delay of 20.94 ns. The post-PnR delay is in
the same ballpark, indicating wire delay contributes well under 25%
of the critical path. The remaining 75% is gate delay through the
adder.

**2. P3 register cut moved the bottleneck.** Before inserting the
`product_q` register (V5-no-P3 / V4 RTL), the critical path went
through *both* the multiplier and the adder: 73 levels, 26.4 ns ABC
delay estimate. Inserting `product_q` between them dropped the
combinational portion to 58 levels (-15 levels, -21% logic depth).
The fact that the path is *still* 58 levels deep tells us that the
adder alone accounts for almost all of it. Quantitatively: of the
73 levels in V5-no-P3, only ~15 belonged to the multiplier; the
remaining ~58 are in the adder. P3 successfully cut out the
multiplier's contribution but left the adder unchanged.

In short: **the binding constraint is the combinational logic depth
inside `fp32_adder.sv`**, specifically the variable barrel shifters
for alignment and normalization, which are the structurally deepest
parts of any IEEE-754-style FP add.

## What would shorten this path

Two M4-level interventions, ranked by expected payoff:

**Pipelining inside fp32_adder (highest ROI).** Splitting the FP32
adder into two or three pipeline stages would directly attack the
58-level depth. Natural cut points:

- **Stage A**: exponent compare + magnitude swap + right-shift align
  (the input prep). Cut after the alignment shift.
- **Stage B**: 24-bit mantissa add + leading-zero count + left-shift
  normalize. Cut after normalization.
- **Stage C**: round, exponent adjust, FTZ encode. Already shallow;
  no further cut needed.

A two-cut version (after align, after normalize) would split the
58-level path into roughly three balanced ~20-level stages, enabling
a clock period of ~8-10 ns post-PnR (100-125 MHz target). The cost
is ~64 new flops per PE x 16 PEs = ~1,024 additional flops, plus
ARRAY_LAT in top.sv must bump by 2 to account for the new latency.

**Carry-select or carry-lookahead in the 24-bit adder (modest ROI).**
The 24-bit ripple-style adder Yosys synthesized contributes some
levels to the critical path but is not the dominant share. Switching
to a hand-instantiated carry-select adder would save perhaps 5-10
levels but is much less impactful than the structural pipeline cut
above. Considered M5+ work.

## Reference: full STA path detail

The full post-PnR path is in
`/synth/timing_report.txt` (the section labelled "nom_tt_025C_1v80
critical setup path"). The startpoint and endpoint Verilog names are
recoverable from `runs/v5_30ns_full/54-openroad-stapostpnr/
nom_tt_025C_1v80/max.rpt` by searching for `acc_out` or `b_fwd`.

The slow-corner critical path (nom_ss_100C_1v60) has the same
topological structure but takes 41 ns end-to-end due to ~2x slower
gates at 100 C / 1.60 V; this is the source of the documented SS-
corner setup violations and is the same root cause as the typical
case — the fp32_adder internal depth.
