# cf04 COPT — Part A: cocotb testbench on `mac_correct.v`

**Author:** Ria (Pratibha Munnangi)
**Course:** ECE 410/510 — Hardware for AI

This directory contains the cocotb-based verification of `mac_correct.v` for the cf04 COPT challenge. It exercises two test cases (`test_mac_basic` and `test_mac_overflow`) and produces a VCD waveform plus a screenshot.

---

## Files

| File | Purpose |
|------|---------|
| `Makefile` | cocotb build/run rules (`make`, `make dump.vcd`, `make wave`) |
| `test_mac.py` | cocotb testbench — `test_mac_basic` and `test_mac_overflow` |
| `mac_correct.v` | DUT (the corrected MAC from cf04 review) |
| `dump.fst` | Waveform in FST format (small, native GTKWave) |
| `dump.vcd.gz` | Same waveform in VCD format, gzipped (8.5 MB → 1.4 MB) |
| `waveform.png` | Screenshot of the basic test (first 50 ns), GTKWave-style |
| `render_wave.py` | Generates `waveform.png` from `dump.vcd` (Matplotlib) |
| `sim.log` | Captured stdout of the cocotb run |

---

## How to run (local sandbox, Icarus + cocotb)

```bash
# From this directory
make SIM=icarus            # runs the testbench
make dump.vcd              # converts sim_build/mac.fst -> dump.vcd
gtkwave dump.vcd           # interactive waveform view
```

Required tools: `iverilog 12+`, `cocotb 2.0+`, `gtkwave` (provides `fst2vcd`).

To re-run a single test:

```bash
make SIM=icarus COCOTB_TESTCASE=test_mac_basic
make SIM=icarus COCOTB_TESTCASE=test_mac_overflow
```

---

## How to run on the PSU server (VCS)

VCS supports SystemVerilog natively and produces VCD via `$vcdpluson` / `$dumpvars`. The cocotb path also works on PSU but requires per-user installation of cocotb 2.0; the simpler equivalent is a Verilog-only re-run of the same testbench using the existing `mac_tb.v` from the cf04 hdl folder. For the cocotb path on PSU:

```bash
# One-time setup (in your home directory on the PSU server)
pip install --user cocotb

# Per-run
cd codefest/cf04/cocotb_mac
make SIM=icarus            # cocotb works with Icarus on PSU too
# OR for VCS:
make SIM=vcs COMPILE_ARGS="-sverilog +v2k -lca"
```

If you only want to rerun the original cf04 Verilog testbench under VCS:

```bash
cd codefest/cf04/hdl
vcs -sverilog -full64 -debug_access+all mac_correct.v mac_tb.v -o mac_sim
./mac_sim
# Use DVE to view the dump
```

---

## Test results

Both tests pass cleanly. From `sim.log`:

```
** test_mac.test_mac_basic        PASS          41.00 ns
** test_mac.test_mac_overflow     PASS    1331461.00 ns
** TESTS=2 PASS=2 FAIL=0 SKIP=0
```

### `test_mac_basic`

Drives the handout-specified stimulus: `a=3, b=4` for 3 cycles, then asserts `rst`.

```
basic: a=3 b=4 -> out=12  (expected 12) OK
basic: a=3 b=4 -> out=24  (expected 24) OK
basic: a=3 b=4 -> out=36  (expected 36) OK
basic: rst -> out=0 OK
```

### `test_mac_overflow` — documented behavior

**Question asked by the handout:** *"Does the design saturate or wrap?"*

**Answer: the design wraps (two's-complement).** It does not saturate.

**How the test exercises this:**

1. Drives `a=127, b=127` (max signed product = 16,129) for 133,144 cycles. This brings the accumulator to exactly `133,144 × 16,129 = 2,147,479,576` — that's `4,071` below `MAX_INT32 (2³¹ − 1 = 2,147,483,647)`.
2. Drives one more `(127, 127)` cycle. Adding `16,129` to the accumulator would give `2,147,495,705` — which exceeds `MAX_INT32` by `12,058`.
3. Observes the output: **`-2,147,471,591`**.

The wrap-around prediction is `2,147,495,705 − 2³² = -2,147,471,591`. The observed value matches the wrap exactly. A saturating design would have clamped to `+2,147,483,647`.

**Why this is the case:**

`mac_correct.v` accumulates with `out <= out + product_ext;` — plain signed addition with no saturation logic. SystemVerilog's `+` operator on a fixed-width signed type has natural two's-complement wraparound at the operand width (32 bits here). To make it saturate would require explicit logic such as:

```verilog
logic signed [32:0] sum_extended;
assign sum_extended = $signed({out[31], out}) + $signed({product_ext[31], product_ext});
always_ff @(posedge clk) begin
    if (rst) out <= '0;
    else if (sum_extended >  32'sh7FFFFFFF) out <= 32'sh7FFFFFFF;  // sat high
    else if (sum_extended < -32'sh80000000) out <= 32'sh80000000;  // sat low
    else                                     out <= sum_extended[31:0];
end
```

This would cost an extra adder bit, two comparators, and a 3:1 mux on the output — meaningful area and timing impact, especially in a 16×16 systolic array (256 PEs). The wrap-vs-saturate decision is a deliberate accuracy/area tradeoff, addressed below.

**Implication for the QKT chiplet (M2):** With INT8 operands and a 32-bit signed accumulator, wrap-around requires accumulating `≥ 2³¹ / (127×127) ≈ 133,144` worst-case products in a single tile. The QKT inner-product reduction length for typical attention head dimensions (`d_k = 64` to `128`) is **far below** this threshold, so wrap-around will not occur in practice. Saturation logic is therefore unnecessary for the M2 design point and the area can be saved.

---

## Waveform

`waveform.png` shows the first 50 ns of the simulation, covering all four phases of `test_mac_basic`:

- Pre-stim reset (rst=1, t≈0–10 ns)
- Three accumulation cycles producing out = 12, 24, 36 (t≈10–40 ns)
- Reset reasserted, out clears to 0 (t≈40–50 ns)

To regenerate the screenshot from the VCD:

```bash
python3 render_wave.py    # writes waveform.png
```

To view the waveform interactively in GTKWave:

```bash
gunzip -k dump.vcd.gz     # if you only have the .gz
gtkwave dump.vcd          # or: gtkwave dump.fst
```

When GTKWave opens, add signals from the `mac` instance: **clk, rst, a, b, out** in that order. Right-click `a`, `b`, `out` → Data Format → Signed Decimal so the values display correctly.

---

## Notes for grading

- Both tests are required to pass for the deliverable; both do.
- The simulation log is captured verbatim in `sim.log`.
- The VCD is provided in two forms: `dump.fst` (smaller, native to GTKWave) and `dump.vcd.gz` (gzipped because the overflow test produces 133K cycles). Either works for `gtkwave`.
- The screenshot deliberately shows the basic test only — the overflow test compresses 1.3 ms of simulation time into a flat line at the picture scale, and wouldn't be visually informative.
