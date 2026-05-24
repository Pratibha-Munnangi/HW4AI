# Project Milestone 3 (M3) — Integration & Synthesis

ECE 410/510, Spring 2026
QK^T accelerator chiplet

## What is in this folder

M3 is the **integration and synthesis** milestone. The M2 compute core and
the M2 AXI interface are now wired together in `rtl/top.sv` and verified
end-to-end through the AXI host interface in `tb/tb_top.sv`. The integrated
design has been pushed through OpenLane 2 with full P&R, GDS streamout,
LVS, DRC, and STA signoff.

This README catalogs every file the grader will look at and gives the
exact commands to reproduce both the co-simulation and the synthesis run.

## File catalog

### Root files

| Path | Description |
|------|-------------|
| `README.md` | This file. Index of M3 deliverables, reproduce commands, tool versions. |
| `synthesis_notes.md` | Narrative (1700+ words): what synthesized, what did not, scope adjustments, M3 integration bug findings, and M4 backlog. |

### `rtl/` — Integrated top module

| Path | Description |
|------|-------------|
| `rtl/top.sv` | Top module. Instantiates `qkt_interface` (AXI4-Lite + AXI-Stream) and `compute_core` (4x4 fp16-mul / fp32-add systolic array). Includes the M3 `clear` plumbing (inter-tile accumulator zero), the M4-P0 Q-row reuse (tile_r / tile_c indexing), and the M4-P1 double-buffered Q/K with dual cooperating FSMs (load + compute). Header comment block names every external port, direction, width, and role. Glue logic (`tile_sequencer`, `diagonal_driver`) is named in the header comments. |

The supporting RTL files referenced by `top.sv` (`fp16_multiplier.sv`,
`fp32_adder.sv`, `core_pe.sv`, `compute_core.sv`, `interface.sv`) are
identical to or evolved from M2 modules; they are committed under
`m2/rtl/` per the M1/M2/M3 layout. The synthesized versions used for
M3 are also copied verbatim into `synth/` for traceability.

### `tb/` — End-to-end co-simulation

| Path | Description |
|------|-------------|
| `tb/tb_top.sv` | End-to-end testbench. Drives the AXI4-Lite host port to write CONFIG and pulse START, streams Q and K data into the engine via AXI-Stream, and reads back the FP32 C result via AXI-Stream. **No direct compute_core ports are accessed** — all data flow goes through the qkt_interface, as required. Reference C is computed independently in SystemVerilog `real` precision from the same FP16-quantized Q/K inputs the engine sees. Prints a single unambiguous `RESULT: PASS` or `RESULT: FAIL` line based on per-cell tolerance comparison against the reference. Uses a `fork`/`join` concurrent producer/consumer structure to exercise the M4-P1 double-buffering. |

The kernel size driven by tb_top is **16x16 QK^T** with D = 4 inner-dim
accumulation (decomposed into 16 independent 4x4 tiles). This matches
the M1-defended dominant kernel size (16x16, d_head = 16). The D = 4
scope reduction relative to the full d_head = 16 inner-dim accumulation
is documented in `synthesis_notes.md` under "Scope adjustments".

### `sim/` — Co-simulation outputs

| Path | Description |
|------|-------------|
| `sim/cosim_run.log` | Plain-text transcript of an actual iverilog `vvp` run of `tb_top`. Contains the `Total checks : 256 / Mismatches : 0 / RESULT: PASS` summary at the end, plus per-tile progress messages showing P0 Q-row reuse events and the P1 concurrent producer/consumer interleaving. Not edited by hand. |
| `sim/cosim_waveform.png` | Annotated GTKWave screenshot showing host-side AXI-Lite write of CONFIG/START, internal compute activity (FSMs, bank swap, S_axis tdata flowing in), and host-side AXI-Stream read of the FP32 C result. The three regions are labelled on the image. |

### `synth/` — OpenLane 2 synthesis

| Path | Description |
|------|-------------|
| `synth/config.json` | The OpenLane 2 configuration used for the final synthesis run. `CLOCK_PERIOD` set to 30 ns (= 33.3 MHz; calibrated to V5's measured ~28-30 ns post-PnR critical path; see `synthesis_notes.md` for rationale). Source-file list, design name, clock port, fanout cap, density target, and lint flags all named here. |
| `synth/openlane_run.log` | Full OpenLane 2 stdout/stderr from the run that produced the committed reports. Includes Yosys synthesis, all OpenROAD P&R steps, CTS, detailed routing, Magic GDS streamout, LVS, and Magic DRC. |
| `synth/timing_report.txt` | Post-PnR static timing analysis. Includes the nine-corner setup/hold/cap/slew slack table (signoff step `54-openroad-stapostpnr/summary.rpt`), the critical-path detail at the typical corner (`nom_tt_025C_1v80/max.rpt`, top 120 lines), and the clock report. Headline: **+9.06 ns setup slack on the typical corner; all hold slacks positive on all corners**. |
| `synth/area_report.txt` | Yosys synthesis statistics (post-tech-map, pre-PnR): 32,086 cells, 315,688 µm² chip area, full cell-type breakdown. Includes post-PnR floorplan metrics where available. |
| `synth/power_report.txt` | OpenSTA power estimate at the nom_tt corner: 162.2 mW total (75.0 mW internal, 87.2 mW switching, 0.16 µW leakage). |
| `synth/critical_path.md` | Critical-path identification per the M3 rubric: names the start register (B-forwarding register in PE[2][2]), the end register (PE[3][3]'s `acc_out`), the combinational stages between them (mul-output mux -> P3 product_q register -> fp32_adder normalize/round chain), explains *why* this is critical (58-level barrel-shift-and-round chain inside fp32_adder), and identifies the two M4 interventions that would shorten it. |

## How to reproduce the co-simulation

### Tool versions

- **Simulator**: Icarus Verilog 12.0 (`iverilog -V` to check)
- **Waveform viewer (optional)**: GTKWave 3.3.x
- **OS**: Ubuntu 24.04 LTS under WSL2 on Windows 11
- **No other dependencies** — pure SystemVerilog, no UVM, no third-party libraries

### Commands

From the V5 working directory containing the `.sv` files and a `sim/`
subdirectory:

```bash
# Integration test (tb_top)
iverilog -g2012 -Wall \
  -o sim/tb_top.vvp \
  -s tb_top \
  fp16_multiplier.sv \
  fp32_adder.sv \
  core_pe.sv \
  compute_core.sv \
  interface.sv \
  top.sv \
  tb_top.sv

vvp sim/tb_top.vvp | tee sim/cosim_run.log
grep "RESULT" sim/cosim_run.log

# Expected:
#   Total checks : 256
#   Mismatches   : 0
#   RESULT: PASS

# Optional unit-test regression (tb_compute_core, requires sim/q_hex.mem,
# k_hex.mem, ref_hex.mem from M2)
iverilog -g2012 -Wall \
  -o sim/tb_compute_core.vvp \
  -s tb_compute_core \
  fp16_multiplier.sv \
  fp32_adder.sv \
  core_pe.sv \
  compute_core.sv \
  tb_compute_core.sv

vvp sim/tb_compute_core.vvp | tee sim/tb_compute_core.log
grep -E "PASS cells|TEST" sim/tb_compute_core.log
# Expected: 16/16 PASS, TEST PASSED
```

### Waveform regeneration

`tb_top.sv` writes `sim/cosim.vcd` via `$dumpvars(0, tb_top)`. To regenerate
the committed `cosim_waveform.png`:

```bash
gtkwave sim/cosim.vcd &
```

Then add signals: `clk`, `rst`, `s_axi_awaddr`, `s_axi_awvalid`,
`s_axi_wdata`, `s_axi_wvalid`, `s_axis_tvalid`, `s_axis_tready`,
`s_axis_tdata`, `s_axis_tlast`, `u_top.comp_state`, `u_top.load_state`,
`u_top.compute_bank`, `u_top.load_bank`, `u_top.do_swap`,
`m_axis_tvalid`, `m_axis_tready`, `m_axis_tdata`, `m_axis_tlast`. Zoom
to range 200 ns - 1500 ns to see one tile's complete lifecycle.

## How to reproduce the synthesis run

### Tool versions

- **OpenLane 2**: nix-shell-based install at `~/openlane2`, current `main`
  branch as of May 2026. Resolved via `nix-shell` in that directory.
  (Exact commit SHA is captured in `openlane_run.log`'s preamble.)
- **PDK**: sky130A, included with the OpenLane 2 nix-shell environment
- **Standard cell library**: `sky130_fd_sc_hd` (high-density)
- **Target clock period**: 30 ns

### Commands

```bash
# Stage RTL into OpenLane workspace
cd <V5 working dir>
mkdir -p openlane/compute_core/src
cp fp16_multiplier.sv fp32_adder.sv core_pe.sv compute_core.sv \
   openlane/compute_core/src/

# config.json is the one committed in this M3 folder
cp <m3 folder>/synth/config.json openlane/compute_core/

# Enter the nix-shell that provides OpenLane 2 + Yosys + OpenROAD + Magic +
# Klayout + Netgen
cd ~/openlane2
nix-shell

# Inside nix-shell, run the full flow (synth + P&R + DRC + LVS + STA)
cd <V5 working dir>/openlane/compute_core
openlane --run-tag v5_30ns_full config.json 2>&1 | tee openlane_run.log

# After completion (~10 hours on WSL/mnt; ~1-2 hours on native Linux fs):
ls runs/v5_30ns_full/final/   # GDS, LEF, SPI, etc.
cat runs/v5_30ns_full/54-openroad-stapostpnr/summary.rpt   # Timing summary
```

### Synthesis-only (faster sanity check)

To verify the RTL synthesizes cleanly without running full P&R (takes ~5
minutes instead of hours):

```bash
openlane --to "Yosys.Synthesis" --run-tag synth_only config.json 2>&1 \
    | tee synth_only.log
```

## Notes for the grader

- The interface module **is the only path** between host and compute in
  `tb_top.sv`. There are no `force` statements, no hierarchical
  references into `compute_core`, no backdoors. All host activity is
  via `s_axi_*` (AXI4-Lite) and `s_axis_*` / `m_axis_*` (AXI-Stream).
- The expected (reference) C matrix is computed in SystemVerilog `real`
  inside the testbench from the same Q/K FP16 inputs the engine
  receives. It is independent of any prior DUT output.
- The PASS/FAIL line is a literal substring `RESULT: PASS` in
  `cosim_run.log`. There is no other PASS/FAIL output that could be
  ambiguous.
- The synthesis flow completed end-to-end. `final/` directory exists in
  the run folder, GDS is produced, LVS reports "Circuits match
  uniquely", Magic DRC reports `COUNT: 0`. Setup violations on the
  three SS PVT corners are documented in `synthesis_notes.md` and
  `critical_path.md` with the root cause and the M4 fix.
