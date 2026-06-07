# M4 Benchmark Results

## Operating Point (matches M1 software baseline exactly)

| Parameter | Value |
|---|---|
| Batch B / Heads H / Sequence T / Head dim d_head | 8 / 4 / 64 / 16 |
| Total FLOPs per call | 4,194,304 (4.19 MFLOPs) |
| Total tiles (4×4) for full workload | 8 × 4 × (64/4)² = 8,192 |
| Kernel | QK^T only (scaled dot-product attention scores) |

---

## §1. Measured Accelerator Throughput

**Measurement method:** Cycle count from tb_top.sv simulation scaled to full workload at post-synthesis fmax.

- tb_top.sv completes 16 tiles of 4×4 in **2,254 simulation cycles** (at 10 ns sim clock)
- Cycles per tile = 2,254 / 16 = **140.9 cycles/tile**
- M4 v2 fmax = **81 MHz** (WNS −4.36 ns at 8 ns target → closes at ~12.4 ns)
- Real time per tile = 140.9 × (1/81 MHz) = **1,739 ns/tile**
- M1 workload (8,192 tiles): 8,192 × 1,739 ns = **14.2 ms**
- **Sustained throughput = 4,194,304 FLOPs / 14.2 ms = 294 MFLOPS**

---

## §2. Speedup vs M1 Software Baseline

**Speedup = (M1 baseline time) / (M4 accelerator time) = 0.981 ms / 14.2 ms = 0.069×**

**M4 v2 is 14.5× SLOWER than the M1 NumPy baseline in throughput.**

This is expected. Three factors explain the gap:
1. **44× clock disadvantage**: 4.4 GHz CPU vs 81 MHz sky130 ASIC
2. **Cache vs streaming**: M1 workload (B=8, T=64) fits in CPU L1/L2; chip streams through AXI-Stream
3. **SIMD width**: AVX2 delivers 80 FP32 MACs/cycle (10 cores × 8-wide) vs 16 scalar PE MACs/cycle

| Baseline | Time | Throughput | M4 v2 speedup |
|---|---|---|---|
| M1 NumPy (i5-1235U + AVX2, FP64) | 0.981 ms | 4,270 MFLOPS | **0.069× (14.5× slower)** |
| Naive Python (pure loops, no NumPy) | ~151 ms | ~27.6 MFLOPS | **10.6× faster** |

---

## §3. Energy Comparison

| Platform | Power | Time | Energy/call | vs M4 v2 |
|---|---|---|---|---|
| i5-1235U CPU (M1 baseline) | 15 W (TDP) | 0.981 ms | 14.7 mJ | 4.9× worse |
| **M4 v2 (this design)** | **212 mW** | **14.2 ms** | **3.02 mJ** | **1× (baseline)** |

**M4 v2 uses 4.9× less energy per QK^T call than the M1 NumPy baseline.**

---

## Progression across design revisions (same workload, all numbers traceable)

| Design | fmax | Time | Throughput | vs M1 | vs Naive Py | Energy | vs M1 |
|---|---|---|---|---|---|---|---|
| M3 V5 | 33 MHz | 424 ms | 9.9 MFLOPS | 0.002× | 0.4× slower | 75 mJ | 5.1× worse |
| M4 v1 (D=4) | 100 MHz | 46.2 ms | 90.9 MFLOPS | 0.021× | 3.3× faster | 5.26 mJ | 2.8× better |
| **M4 v2 (d-chain)** | **81 MHz** | **14.2 ms** | **294 MFLOPS** | **0.069×** | **10.6× faster** | **3.02 mJ** | **4.9× better** |

---

## Roofline summary

See bench/roofline_final.png for the plot.

| Design | AI (FLOP/byte) | Regime | Achievable |
|---|---|---|---|
| M3 V5, M4 v1 | 0.5 | Memory-bound | 0.65 GFLOPS |
| M4 v2 + P0 reuse | **~3.5** | **Compute-bound ★** | **~2.59 GFLOPS** |

Ridge point: 2.0 FLOP/byte. M4 v2 crosses it via d-chaining + Q-row reuse.

---

*Raw data: bench/benchmark_data.csv*
*Simulation log: sim/final_run.log*
*Synthesis power: synth/power_report.txt (212 mW at nom_tt)*
