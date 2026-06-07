# project/m4/ — M4 Final Submission Catalog

**Pratibha Munnangi** | ECE 410/510, Spring 2026 | Prof. Teuscher

Every file in this folder with a one-line description and the checklist item
or report section it supports.

---

## RTL — `rtl/`

| File | Description | Supports |
|---|---|---|
| `rtl/fp16_multiplier.sv` | FP16×FP16→FP32 combinational multiplier (unchanged from M2) | §4 Dataflow, §6 Verification |
| `rtl/fp32_adder_pipelined.sv` | 3-stage pipelined FP32 adder with V5 carry-out equal-magnitude bugfix | §4 Dataflow, §7 Synthesis |
| `rtl/core_pe.sv` | Per-PE: FP16 mul, tree-reduce, d-chain accumulation over N_BLOCKS=4, tile_acc | §4 Dataflow, §6 Verification |
| `rtl/compute_core.sv` | 4×4 systolic array of 16 core_pe instances, valid/block_clear/block_first/last routing | §4 Dataflow, §7 Synthesis |
| `rtl/interface.sv` | AXI4-Lite CSR (VERSION/CONFIG/CTRL/STATUS) + AXI4-Stream passthrough | §5 Hardware Interface |
| `rtl/top.sv` | Top-level: dual-FSM load+compute, P0 Q-reuse, P1 double-buffer, d-block outer loop, D_TOTAL=16 | §4 Dataflow, §7 Synthesis |

---

## Testbenches — `tb/`

| File | Description | Supports |
|---|---|---|
| `tb/tb_fp32_adder_pipelined.sv` | 272-vector standalone regression for fp32_adder_pipelined (directed + random) | Checklist §2, §6 Verification |
| `tb/tb_core_pe_chain.sv` | 74-case PE d-chain regression: 1/2/4 d-blocks, corners, cancellation | Checklist §2, §6 Verification |
| `tb/tb_top.sv` | Full-chip AXI integration: 16 tiles × 16 outputs, d_head=16, 256 checks | Checklist §2, §6 Verification |

---

## Simulation — `sim/`

| File | Description | Supports |
|---|---|---|
| `sim/final_run.log` | tb_top.sv output: PASS 256/256, 0 mismatches, d_head=16 | Checklist §2 |
| `sim/final_waveform.png` | Annotated timing diagram of one complete 4×4 tile transaction (Q load → compute → drain) | Checklist §2, §6 Verification |
| `sim/fp32_adder_ref.py` | Bit-exact Python emulator for fp32_adder_pipelined including carry-out fix | §6 Verification |
| `sim/pe_vector_gen.py` | Single-block PE test vector generator | §6 Verification |
| `sim/pe_chain_vector_gen.py` | Multi-block (d-chain) PE test vector generator using tree-reduce reference | §6 Verification |

---

## Synthesis — `synth/`

| File | Description | Supports |
|---|---|---|
| `synth/config.json` | OpenLane 2 config: sky130A, 8 ns clock, 1500×1500 µm die, FP_CORE_UTIL=50 | Checklist §3 |
| `synth/openlane_run.log` | Full captured stdout from OpenLane 2 run (78/78 stages, DRC/LVS clean) | Checklist §3 |
| `synth/timing_report.txt` | Post-PnR timing (nom_tt_025C_1v80): WNS −4.36 ns, critical path in fp32_adder S2 | Checklist §3, §7 Synthesis |
| `synth/area_report.txt` | Yosys synthesis state: 85,545 cells, 928K µm² cell area | Checklist §3, §7 Synthesis |
| `synth/power_report.txt` | OpenSTA power: 212 mW total (35% seq / 37% comb / 28% clock) | Checklist §3, §7 Synthesis |

---

## Benchmark — `bench/`

| File | Description | Supports |
|---|---|---|
| `bench/benchmark.md` | Throughput (294 MFLOPS), speedup vs M1 (0.069×, 14.5× slower), energy (4.9× better), measurement method | Checklist §4 |
| `bench/benchmark_data.csv` | Raw numbers behind all benchmark claims, 36 rows, each with source file | Checklist §4 |
| `bench/roofline_final.png` | Log-log roofline: M4 v2 hardware roofline, M1 SW baseline, M3/v1/v2 measured operating points | Checklist §4, §2 Roofline |

---

## Report — `report/`

| File | Description | Supports |
|---|---|---|
| `report/design_justification.pdf` | 9-section design justification report (~3,500 words) | Checklist §5 |
| `report/figures/block_diagram.png` | Figure 1: Top-level system block diagram (referenced in §4 Dataflow) | §4 Dataflow |
| `report/figures/roofline_final.png` | Figure 2: Roofline analysis with all 4 operating points (referenced in §2 Roofline) | §2 Roofline |
| `report/figures/final_waveform.png` | Figure 3: Annotated tile transaction waveform (referenced in §6 Verification) | §6 Verification |

---

## Differences from M3

| Component | M3 V5 | M4 v2 |
|---|---|---|
| FP32 adder | Combinational ~58 logic levels | 3-stage pipelined ~18 levels/stage |
| PE accumulation | Accumulator-in-loop (data hazard) | Tree-reduce + d-chain over N_BLOCKS=4 |
| Inner dimension per call | D=4 (partial, 4 invocations for d_head=16) | D_TOTAL=16 (full d_head in one call) |
| Arithmetic intensity | 0.5 FLOP/byte (memory-bound) | ~3.5 FLOP/byte (compute-bound with P0) |
| fmax | 33 MHz | ~81 MHz |
| Power | 177 mW | 212 mW |
| Cells | ~33,000 | 85,545 |

---

## Verification Summary

| Testbench | Vectors | Result |
|---|---|---|
| tb_fp32_adder_pipelined | 272 | **PASS 272/272** |
| tb_core_pe_chain | 74 | **PASS 74/74** |
| tb_top (full chip integration) | 256 | **PASS 256/256** |

Simulation environment: Icarus Verilog 12.0, Ubuntu 22.04 / WSL2.
