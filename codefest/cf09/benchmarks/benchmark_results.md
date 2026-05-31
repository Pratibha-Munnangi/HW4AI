# CF09 — CLLM Benchmark Results
**ECE 410/510: Hardware for AI and ML, Spring 2026**
**Codefest 09 — Benchmark Comparison (Task 6–8)**
**Path:** `codefest/cf09/benchmarks/benchmark_results.md`

---

## Workload definition

Both sides benchmark the **QKᵀ scaled dot-product score computation**
at the M1 operating point: B=8, H=4, T=64, d_head=16. One full
invocation = **4,194,304 FLOPs (4.19 MFLOPs)**.

Per-invocation FLOPs formula: `2 × B × H × T² × d_head`.

## Method

- **Software baseline (M1):** wall-clock, `time.perf_counter`, median
  of 10 runs. Same data, same code as M1 submission (`project/m1/
  qkt_baseline.py`). Re-confirmed numbers; no change from M1 report.
- **Hardware accelerator (V5):** cycle-accurate simulation via
  `iverilog tb_top` from M3 V5 submission. tb_top is fully runnable
  and passes 256/256 bit-exact at `nom_tt` corner (`project/m3/sim/
  tb_top.log`). One invocation = one 16×16 scope-reduced QKᵀ
  (D=4 inner-dim per tile; see "Extrapolation methodology" below).
- **Projected peak (V5 and M4):** synthesis-derived, computed as
  `clock × PEs × FLOPs/cycle`. Labeled **PROJECTED** in every row
  per the M4 spec requirement.

## Results table

| Setting | Method | Throughput | Runtime (M1 workload, 4.19 MFLOPs) | Power | Energy (M1 workload) | Speedup vs SW |
|---|---|---|---|---|---|---|
| **M1 software baseline** (i5-1235U, NumPy FP64) | Measured (wall-clock, median of 10) | **4.275 GFLOP/s** | 981.1 µs | ~28 W (sustained turbo, est.) | ~27.47 mJ (est.) | 1.00× (reference) |
| **M3 V5 hardware, scope-reduced** (sky130, FP16×FP32, 33.3 MHz, D=4) | Measured tb_top, single invocation | 0.221 GFLOP/s | 9.255 µs/inv → 18.95 ms total (extrapolated, 2048 inv) | 162.2 mW (OpenSTA est.) | 3.07 mJ | **0.052× (19.3× slower)** |
| **M3 V5 projected peak** (no utilization losses, no scope reduction) | PROJECTED (`16 PE × 2 FLOPs × 33.3 MHz`) | 1.067 GFLOPS | 3.94 ms | ~162.2 mW | ~0.64 mJ | 0.25× (4.0× slower) |
| **M4 projected peak** (after P-top adder pipeline → ~100 MHz) | PROJECTED (`16 PE × 2 FLOPs × 100 MHz`) | 3.200 GFLOPS | 1.31 ms | ~200 mW (est., scales w/ f) | ~0.26 mJ | **0.75× (1.34× slower)** |

## Speedup interpretation

The hardware accelerator is **slower than the software baseline on
raw throughput** at every point along the project trajectory. Stated
plainly:

- V5 *as it exists today* runs the same workload **19.3× slower** than
  the M1 software baseline.
- Even at projected M4 peak performance (after the adder-pipelining
  unlock), the hardware reaches only **~75% of M1 software throughput**.

This is the expected outcome of a sky130-class chiplet compared
against a 10nm-class Intel CPU running NumPy. The CPU has two AVX2 P-
cores at 4.4 GHz with hundreds of millions of transistors of cache
and vector machinery; the accelerator has 16 PEs at 33.3 MHz in
0.32 mm² of sky130. Throughput parity was never the design goal.

## Where the hardware wins: energy

The chiplet uses **~8.9× less energy** for the same workload (3.07 mJ
HW vs 27.47 mJ SW, both estimates). Per-MAC energy comparison:

- HW: 3.07 mJ / 2.1 MMACs = ~1.47 nJ per MAC
- SW: 27.47 mJ / 2.1 MMACs = ~13.1 nJ per MAC

This 9× efficiency gap is the **defensible academic result** for the
M3 V5 chiplet. At projected M4 throughput (1.31 ms runtime, similar
power), the energy advantage widens to roughly **~50× per operation**
because the hardware finishes faster without proportional power
increase.

## Extrapolation methodology (Task 7 fallback path)

The V5 design implements a **scope-reduced QKᵀ**: each tb_top
invocation produces a 16×16 result matrix but accumulates only D=4
of the d_head=16 inner-dimension values (per `project/m3/synth/
synthesis_notes.md`, §"Scope adjustments"). One V5 invocation
therefore performs:

```
FLOPs per V5 invocation = 16 × 16 outputs × 4 d-values × 2 FLOPs/MAC
                        = 2,048 FLOPs in 9,255 ns
                        = 0.2213 GFLOP/s measured
```

To compare against M1's full workload (4,194,304 FLOPs):

```
V5 invocations to match M1 workload = 4,194,304 / 2,048 = 2,048 invocations
Extrapolated wall-clock              = 2,048 × 9,255 ns  = 18.954 ms
```

**Extrapolation assumptions (explicit, per rubric):**

1. **Linear scaling:** the per-invocation V5 runtime is assumed
   constant across the 2,048 invocations required for the M1
   workload. This is the *pessimistic* assumption — it does not
   credit M4's planned d-chaining (P-acc), which would amortize
   per-tile load/drain overhead across multiple d-values and could
   reduce total runtime by ~20–40%.
2. **No host-side accumulation cost:** the host-side d-dim
   accumulation needed to reconstruct full d=16 from four D=4
   passes (~393 K additions across the workload) is not counted in
   the HW runtime. This is a small fraction of the 4.19 M FLOPs
   total but is real overhead that an end-to-end measurement
   would include.
3. **No host↔chiplet AXI4-Stream contention:** the model assumes
   the host can feed Q/K and accept scores back at AXI4-Stream rate
   for all 2,048 invocations without queueing stalls. Real-system
   performance may differ.
4. **Power constant across utilization:** the 162.2 mW OpenSTA
   estimate is at the typical-corner activity factor used by
   OpenLane defaults, not measured with a SAIF file from the
   benchmark workload. M4 will replace this with SAIF-driven power.

**Path to converting projected → measured for M4:** run tb_top with
a multi-d-block test driver that exercises the full d=16 sum (via
host-side accumulation between invocations), measure the
end-to-end runtime, and use that number as the M4 benchmark.
The M4 P-acc backlog item adds D-chaining inside the engine so
this becomes one back-to-back run rather than software-orchestrated.

## Raw measurement data

See `benchmark_data.csv` for the underlying numbers, including all
ten M1 software runs, the V5 tb_top transaction log timestamps, and
the synthesis-derived projection inputs.

## References

- M1 SW baseline: `project/m1/sw_baseline.md` (re-confirmed for CF09)
- V5 measured runtime: `project/m3/sim/tb_top.log`, runtime line 9,255 ns
- V5 synthesis numbers: `project/m3/synth/synthesis_notes.md`
- M3 power: `project/m3/synth/power_report.txt` (OpenSTA, 162.2 mW)
- M4 target: `project/m3/synth/critical_path.md` (P-top, 100 MHz target)
