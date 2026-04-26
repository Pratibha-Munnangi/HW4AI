# ECE 410/510 Spring 2026

**Name:** Pratibha Munnangi  
**Course:** ECE 410/510 — Spring 2026  
**Tentative Project Topic:** Hardware Accelerator for QKᵀ Matrix Multiplication in Transformer Self-Attention


# project/hdl — QKT compute core

## Module — `core_pe`

One processing element of the 16×16 output-stationary INT8 systolic MAC array. On each clock with `en=1`, computes `a_in × b_in` and adds the signed product to the local accumulator; forwards `a_in`/`b_in` to the next PE in the row/column with one cycle of skew. Synchronous active-high reset clears the accumulator. Parameterized for `A_WIDTH`, `B_WIDTH`, `ACC_WIDTH` (defaults 8/8/32). The full 16×16 array wiring is M2.

## Interface — AXI4-Stream (data) + AXI4-Lite (control)

Streaming carries Q rows and K columns into the array; AXI4-Lite handles control register access. `core_pe` exposes a bare `(a_in, b_in, en, rst, clk)` interface; AXI shells live one level up.

**Justification (M1 arithmetic intensity):** QKT has an AI of ~1 FLOP/byte without reuse, but the 16×16 systolic arrangement reuses each Q-row and K-col element 16 times, raising effective AI to ~10–14 FLOPs/byte and putting the workload in the compute-bound regime. The interface only needs to sustain the array's input edge: 16 row + 16 col INT8 bytes per cycle = 32 B/cycle = **16 GB/s at 500 MHz**. A 32-bit AXI4-Stream gives only 2 GB/s, so the data path needs **256-bit AXI4-Stream at 500 MHz**. AXI4-Lite suffices for control because writes happen once per matrix and don't gate throughput.

## Precision — INT8 in, INT32 accumulate, FP32 dequantized out

INT8 round-trip MAE on a representative weight matrix is ~0.004 with symmetric per-tensor scaling — small enough for attention. Worst-case accumulated error scales with `d_k` (~0.55 for `d_k=128`), bounded only if the accumulator keeps full precision: INT32 gives 16 bits of headroom over the 16-bit signed product. FP32 inside the PE would be worse (only 23 mantissa bits, ~3× the gate count). FP32 dequantization happens once per output tile via per-tensor scales `S_q × S_k`, amortized over `d_k` MACs.
