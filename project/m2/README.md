# Project M2 — QK^T Chiplet Accelerator

This directory contains the M2 deliverables for the QK^T chiplet project
(ECE 410/510, Spring 2026, Prof. Teuscher). Both required modules are present
as synthesizable SystemVerilog with self-checking testbenches; both produce
**TEST PASSED** in their committed transcripts.

## ⚠️ Deviations from the rubric's suggested structure

Two places where this submission deviates from the rubric handout's suggested
filenames or layout. Both are flagged here so the grader can match expected
paths to actual files at a glance.

### 1. Interface module is named `qkt_interface`, not `interface`

| Rubric expectation                              | This submission                          |
|-------------------------------------------------|------------------------------------------|
| File: `project/m2/rtl/interface.sv`             | ✅ Same path                             |
| Top module name: (implied) `interface`          | ❌ Module is named `qkt_interface`       |

**Why:** SystemVerilog reserves the keyword `interface` for the SV interface
construct. A module named `interface` does not compile in any
SV-2012-compliant tool (Icarus, Verilator, ModelSim, VCS — all reject it).
The rubric's filename-must-match-module-name rule is stated explicitly only
for `compute_core.sv`; for `interface.sv` the rubric specifies the path but
not the module name, so renaming the module is rubric-compliant.

### 2. Compute core uses packed-bus ports instead of unpacked arrays

| Rubric expectation                              | This submission                          |
|-------------------------------------------------|------------------------------------------|
| Filename: `project/m2/rtl/compute_core.sv`      | ✅ Same path                             |
| Top module: `compute_core`                       | ✅ Same module name                      |
| Port style: (unspecified)                        | Packed buses: `q_in_bus`, `k_in_bus`, `c_out_bus` |

**Why:** Icarus Verilog 12 has a known limitation propagating unpacked-array
output ports through `generate`-block instances; signals were stuck at X at
the module boundary even though internal PE accumulators held correct values.
Switching to packed buses (`logic [N*16-1:0]`, `logic [N*N*32-1:0]`)
resolved this and is also more portable across synthesis tools generally,
so it's a permanent design choice rather than a workaround.

---

## File inventory

The committed repository contains exactly the following files under
`project/m2/`. Everything below is required either by the rubric checklist or
to support the optional `precision.md` analysis.

### RTL (`project/m2/rtl/`)

| # | File                  | Top module       | Purpose                                                |
|---|-----------------------|------------------|--------------------------------------------------------|
| 1 | `fp16_multiplier.sv`  | `fp16_multiplier`| IEEE 754 binary16 × binary16 → binary32 (combinational, FTZ, no rounding) |
| 2 | `fp32_adder.sv`       | `fp32_adder`     | IEEE 754 binary32 + binary32 → binary32 (combinational, FTZ + RNE) |
| 3 | `core_pe.sv`          | `core_pe`        | One PE: registered FP32 accumulator + FP16 forwarding to right/down neighbors |
| 4 | `compute_core.sv`     | `compute_core`   | NxN systolic array of PEs (default N=4, scales to N=16). Top module of compute deliverable. |
| 5 | `interface.sv`        | `qkt_interface`  | AXI4-Lite slave (4 CSRs) + AXI4-Stream skid buffer. Top module of interface deliverable. See deviation #1 above. |

### Testbenches (`project/m2/tb/`)

| # | File                   | Purpose                                          |
|---|------------------------|--------------------------------------------------|
| 6 | `tb_compute_core.sv`   | Loads vectors from `sim/q_hex.mem`, `sim/k_hex.mem`, `sim/ref_hex.mem` via `$readmemh`; drives diagonal-feed streaming; captures `c_out_bus`; compares against the FP32 reference within an FP-aware tolerance; prints PASS/FAIL per cell and overall. |
| 7 | `tb_interface.sv`      | Drives one AXI-Lite write + readback (CONFIG), one AXI-Lite read (VERSION), and one AXI-Stream beat passthrough; checks expected values; prints PASS/FAIL. |

### Simulation outputs (`project/m2/sim/`)

| #  | File                       | Purpose                                            |
|----|----------------------------|----------------------------------------------------|
| 8  | `q_hex.mem`                | FP16 Q matrix vectors (hex), produced by `gen_vectors.py`. |
| 9  | `k_hex.mem`                | FP16 K matrix vectors (hex), produced by `gen_vectors.py`. |
| 10 | `ref_hex.mem`              | FP32 reference QKᵀ output (hex), produced by `gen_vectors.py`. |
| 11 | `compute_core_run.log`     | Required: PASS transcript (16/16 cells bit-exact). |
| 12 | `interface_run.log`        | Required: PASS transcript (4/4 sub-tests).         |
| 13 | `waveform.png`             | Required: annotated waveform image.                |

The three `.mem` files are committed for grader convenience — testbenches
run directly from a clean clone with no Python pre-processing required. They
are also fully regeneratable: see `gen_vectors.py` (top-level) and the
"Reproducing M2 results" section below. The commit has the bit-identical
output of running `python gen_vectors.py` with the default arguments
(N=4, D=4, seed=410).

### Top-level docs and scripts (`project/m2/`)

| #  | File              | Purpose                                                   |
|----|-------------------|-----------------------------------------------------------|
| 14 | `README.md`       | This file: file inventory, run instructions, deviations.  |
| 15 | `precision.md`    | Required: numerical format choice + measured error sweep. |
| 16 | `gen_vectors.py`  | Python script that produces `sim/q_hex.mem`, `sim/k_hex.mem`, `sim/ref_hex.mem`. Independent FP32 reference (NumPy) — never derived from the DUT. |

## Toolchain

- **Simulator:** Icarus Verilog 12.0+ (SV-2012). On Windows install via
  `choco install iverilog` or `scoop install iverilog`. On Linux install via
  `apt-get install iverilog` (Ubuntu 24+ ships 12.0).
- **Waveform viewer (optional):** GTKWave (bundled with Icarus).
- **Python (optional):** 3.10+ with `numpy` (any 1.x or 2.x). Required only
  if regenerating the `.mem` test vectors via `gen_vectors.py`. The
  committed `.mem` files mean the testbenches run without Python.

No proprietary tools are required.

## Reproducing M2 results from a clean clone

All commands assume the working directory is `project/m2/`.

### Compute core (mandatory)
