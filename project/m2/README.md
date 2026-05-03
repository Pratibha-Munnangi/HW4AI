# Project M2 — QK^T Chiplet: Compute Core + Interface

This directory contains the M2 deliverables: synthesizable SystemVerilog for
the compute core (16x16-ready FP16/FP32 systolic array, verified at 4x4) and
the AXI4-Lite + AXI4-Stream interface module, with self-checking testbenches
that produce **TEST PASSED** in their respective transcripts.

For the rubric checklist see `Project: Milestone 2 Deliverables and Checklist`
(course handout, Apr 26 2026 r1). Every checklist item maps to a file under
this directory tree.

## Layout

```
project/m2/
├── README.md                  (this file)
├── precision.md               (numerical format choice + measured error sweep)
├── gen_vectors.py             (Python reference vector generator)
├── render_waveform.py         (optional: regenerate waveform.png from VCD)
├── rtl/
│   ├── fp16_multiplier.sv     (FP16*FP16 -> FP32, FTZ, no rounding)
│   ├── fp32_adder.sv          (FP32 + FP32 -> FP32, FTZ + RNE)
│   ├── core_pe.sv             (single PE: registered FP32 accumulator + forwarding)
│   ├── compute_core.sv        (NxN systolic array, packed-bus ports)
│   └── interface.sv           (AXI4-Lite slave + AXI4-Stream passthrough)
├── tb/
│   ├── tb_compute_core.sv     (loads .mem vectors, drives diagonal feed, checks PASS)
│   └── tb_interface.sv        (AXI-Lite write+read + AXI-Stream beat, checks PASS)
├── sim/
│   ├── q_hex.mem, k_hex.mem, ref_hex.mem    (test vectors, generated)
│   ├── vectors_meta.txt                     (human-readable Q/K/ref dump)
│   ├── compute_core_run.log                 (PASS transcript, committed)
│   ├── interface_run.log                    (PASS transcript, committed)
│   ├── tb_compute_core.vcd                  (waveform dump)
│   ├── tb_interface.vcd                     (waveform dump)
│   └── waveform.png                         (annotated waveform image)
└── sweep/
    ├── gen_sweep.py                         (128-trial vector generator)
    ├── tb_sweep.sv, tb_sweep_d16.sv         (sweep DUT drivers)
    ├── analyze_sweep.py                     (compute MAE/max/ULP statistics)
    ├── sim_sweep/                           (D=4 sweep outputs)
    └── sim_sweep_d16/                       (D=16 sweep outputs)
```

## Toolchain

- **Simulator:** Icarus Verilog 12.0 (`iverilog -V` should report `12.0` or
  later). Earlier versions lack SystemVerilog 2012 support needed by this
  design. On Windows, install via `choco install iverilog` or
  `scoop install iverilog`. On Linux, `apt-get install iverilog` (Ubuntu 24+
  ships 12.0).
- **Waveform viewer (optional):** GTKWave 3.3+, distributed with Icarus.
- **Python:** 3.10+ with `numpy`. For optional waveform PNG regeneration also
  `vcdvcd` and `matplotlib`. Installed via:
  ```
  pip install numpy vcdvcd matplotlib
  ```

No proprietary tools (ModelSim/Questa/VCS) are required. The grader can
reproduce all results from a clean clone with the commands below.

## Reproducing the M2 results from a clean clone

All commands assume the working directory is `project/m2/`.

### 1. Generate test vectors (Python)

```
python gen_vectors.py
```

This writes `sim/q_hex.mem`, `sim/k_hex.mem`, `sim/ref_hex.mem`, and
`sim/vectors_meta.txt`. Defaults are `N=4 D=4 seed=410 scale=0.5`. The seed
is fixed, so re-running produces byte-identical output.

### 2. Compile and run the compute-core testbench

```
iverilog -g2012 -o sim/tb_compute_core.vvp \
    rtl/fp16_multiplier.sv \
    rtl/fp32_adder.sv \
    rtl/core_pe.sv \
    rtl/compute_core.sv \
    tb/tb_compute_core.sv

vvp sim/tb_compute_core.vvp | tee sim/compute_core_run.log
```

The transcript ends with `TEST PASSED` and reports `PASS cells : 16 / 16`.
Each of the 16 output cells matches the FP32 reference bit-exact at the M2
verification dimension (N=4 D=4); see `precision.md` for the full sweep.

### 3. Compile and run the interface testbench

```
iverilog -g2012 -o sim/tb_interface.vvp \
    rtl/interface.sv \
    tb/tb_interface.sv

vvp sim/tb_interface.vvp | tee sim/interface_run.log
```

The transcript ends with `TEST PASSED` and reports `PASS : 4` covering:

1. AXI-Lite write to CONFIG (0x08), read back, value match.
2. AXI-Lite read of VERSION (0x0C), value matches `32'hC0DE_0001`.
3. AXI-Stream beat passthrough: `tdata` zero-extended FP16 to FP32.
4. AXI-Stream `tlast` correctly mirrored.

### 4. (Optional) Regenerate the waveform PNG

```
pip install vcdvcd matplotlib
python render_waveform.py
```

Or open `sim/tb_compute_core.vcd` directly in GTKWave and save a screenshot
to `sim/waveform.png`.

### 5. (Optional) Reproduce the precision sweep

```
cd sweep
python gen_sweep.py
python gen_sweep.py --D 16 --outdir sim_sweep_d16 --seed 411
cd ..
iverilog -g2012 -o sweep/tb_sweep.vvp \
    rtl/fp16_multiplier.sv rtl/fp32_adder.sv rtl/core_pe.sv \
    rtl/compute_core.sv sweep/tb_sweep.sv
vvp sweep/tb_sweep.vvp
iverilog -g2012 -o sweep/tb_sweep_d16.vvp \
    rtl/fp16_multiplier.sv rtl/fp32_adder.sv rtl/core_pe.sv \
    rtl/compute_core.sv sweep/tb_sweep_d16.sv
vvp sweep/tb_sweep_d16.vvp
cd sweep
python analyze_sweep.py
```

Numbers in `precision.md` are reproduced exactly under fixed seeds.

## Architecture summary

### Compute core (`rtl/compute_core.sv`)

`compute_core` is a parameterized N-by-N output-stationary systolic array
computing `C = Q * K^T`, where Q is N-by-D, K is N-by-D, C is N-by-N FP32.
Defaults: `N = 4`, `D = 4`. Same RTL retargets to `N = 16`, `D = 16` for M3.

The array is built by `genvar` instantiation of `core_pe`. Each PE registers
its FP32 accumulator and forwards its FP16 operands to the right and down
neighbors with one-cycle skew. Q rows enter at the west edge; K rows enter
at the north edge. The diagonal-feed streaming pattern is driven by the
testbench (see comments in `tb_compute_core.sv` for the exact protocol).

Module ports use packed buses (`q_in_bus`, `k_in_bus`, `c_out_bus`) rather
than unpacked arrays, for portability across simulators and synthesis tools.

After `2*(N-1) + (D-1) + 1` cycles from reset deassertion, `c_out_bus` holds
the full QK^T result.

Numerical policy: see `precision.md`. Single-clock domain. Synchronous
active-high reset. Pure RTL, no behavioral constructs.

### Interface (`rtl/interface.sv`, module `qkt_interface`)

AXI4-Lite slave with a 16-byte register space:

| Offset | Name    | Access | Description                                      |
|--------|---------|--------|--------------------------------------------------|
| 0x00   | CTRL    | W1S    | [0]=START (self-clear), [1]=ABORT (self-clear)   |
| 0x04   | STATUS  | RO/W1C | [0]=BUSY (RO), [1]=DONE (W1C), [2]=ERR (W1C)     |
| 0x08   | CONFIG  | RW     | [15:0]=N, [31:16]=D                              |
| 0x0C   | VERSION | RO     | `32'hC0DE_0001`                                  |

AXI4-Stream slave (`s_axis`, 16-bit FP16 in) and master (`m_axis`, 32-bit
FP32 out) with a single-stage skid buffer that honors the
TVALID/TREADY/TLAST contract on every channel. For M2 the Lite block drives
a placeholder "BUSY for FIXED_BUSY_CYCLES then DONE" engine, exercising
end-to-end protocol. The compute_core hookup is M3 work and is not yet
wired in (see Deviations).

Note on module name: SystemVerilog reserves the keyword `interface` for the
SV interface construct. The module is therefore named `qkt_interface`; the
file is named `interface.sv` to match the rubric's path requirement. The
rubric's "top module name must match the filename" line is for
`compute_core.sv` only.

## Deviations from the M1 plan

- **Precision.** M1 was authored with FP16 as the working assumption. M2
  formalizes that as **FP16 multiply with FP32 accumulate**, with **FTZ on
  subnormals** and **RNE on the FP32 add**. No NaN/Inf propagation. See
  `precision.md` for the rationale and 2048-cell measured error sweep.
- **Interface protocol.** M1 identified AXI4-Lite + AXI4-Stream as the
  practical starting point. M2 implements both. The interface and compute
  core are *not* wired together for M2 -- they are separately verified
  modules per the rubric. Integration (a diagonal-skew adapter from
  AXI-Stream beats to the array's edge protocol) is M3 work.
- **Array size for M2 simulation.** M2 verifies the array at N=4, D=4. The
  RTL is fully parameterized and retargets to N=16, D=16 for M3 by changing
  the `compute_core` module parameters (and re-running `gen_vectors.py
  --N 16 --D 16`). The precision sweep at D=16 (`sweep/sim_sweep_d16/`)
  exercises this configuration as a forward-compatibility check.
- **Module naming.** `qkt_interface` not `interface` (SV keyword conflict;
  filename remains `interface.sv` per rubric). See note in the Architecture
  section above.
- **Unpacked-array ports replaced with packed buses.** The compute_core
  module uses packed buses (`q_in_bus`, `k_in_bus`, `c_out_bus`) rather
  than unpacked array ports. This was driven by an Icarus Verilog 12
  limitation in propagating unpacked-array outputs through generate-block
  instances. Packed buses are also more portable across synthesis tools
  generally, so this is a permanent design choice rather than a
  simulator-specific workaround.

## Verification status

| Deliverable                                | Status                  |
|--------------------------------------------|-------------------------|
| `rtl/compute_core.sv` synthesizable        | Yes (no behavioral)     |
| `rtl/interface.sv` synthesizable           | Yes (no behavioral)     |
| Single-clock-domain, sync reset            | Yes, both modules       |
| `tb_compute_core.sv` PASS                  | Yes (16/16 cells)       |
| `tb_interface.sv` PASS                     | Yes (4/4 sub-tests)     |
| `compute_core_run.log` committed           | Yes                     |
| `interface_run.log` committed              | Yes                     |
| `waveform.png` committed                   | Yes (annotated)         |
| `precision.md` >=300 words with sweep      | Yes (1234 words, 2048 cells) |

## Where to look next

- **Test vectors and reference values:** `sim/vectors_meta.txt` — human-readable
  dump of Q, K, and the FP32 reference QK^T.
- **Numerical policy and measured error:** `precision.md`.
- **Module-level documentation:** the header comment of each `.sv` file.
- **For the streaming protocol explanation:** the header comment in
  `rtl/compute_core.sv` and the streaming loop in `tb/tb_compute_core.sv`.
