# mac_code_review.md — cf04

**Author:** Pratibha Munnangi
**Course:** ECE 410/510 — Hardware for AI
**Codefest:** cf04 (MAC module, two-LLM comparison)

---

## Task 1 — Generate (LLM attribution)

Two LLMs were prompted with the identical specification 

| File | LLM that produced it |
|------|---------------------|
| `codefest/cf04/hdl/mac_llm_A.v` |  Claude Opus 4.7 |
| `codefest/cf04/hdl/mac_llm_B.v` | ChatGPT 4o  |

Both files declare module `mac` with the spec port list, use `always_ff @(posedge clk)`, and contain no `initial` blocks, no `$display`, and no `#` delays. The four hard constraints from the spec are satisfied at the source level by both files.

---

## Task 2 — Compile / Lint (verbatim output)

Both files were checked with `iverilog -g2012 -Wall` and `verilator --lint-only -Wall`.

### 2.1 `iverilog` — `mac_llm_A.v`

```
$ iverilog -g2012 -Wall -o /tmp/A_check mac_llm_A.v
exit=0
```

No warnings, no errors.

### 2.2 `iverilog` — `mac_llm_B.v`

```
$ iverilog -g2012 -Wall -o /tmp/B_check mac_llm_B.v
exit=0
```

No warnings, no errors.

### 2.3 `verilator --lint-only` — `mac_llm_A.v`

```
$ verilator --lint-only -Wall mac_llm_A.v
%Warning-DECLFILENAME: mac_llm_A.v:15:8: Filename 'mac_llm_A' does not match MODULE name: 'mac'
   15 | module mac (
      |        ^~~
                       ... For warning description see https://verilator.org/warn/DECLFILENAME?v=5.020
                       ... Use "/* verilator lint_off DECLFILENAME */" and lint_on around source to disable this message.
%Error: Exiting due to 1 warning(s)
exit=1
```

Only the `DECLFILENAME` notice — a filename-vs-module-name convention message, not a code defect. The filename is dictated by the assignment naming rule (`mac_llm_A.v`). **No substantive lint issues.**

### 2.4 `verilator --lint-only` — `mac_llm_B.v`

```
$ verilator --lint-only -Wall mac_llm_B.v
%Warning-DECLFILENAME: mac_llm_B.v:1:8: Filename 'mac_llm_B' does not match MODULE name: 'mac'
    1 | module mac (
      |        ^~~
                       ... For warning description see https://verilator.org/warn/DECLFILENAME?v=5.020
                       ... Use "/* verilator lint_off DECLFILENAME */" and lint_on around source to disable this message.
%Warning-WIDTHEXPAND: mac_llm_B.v:17:24: Operator ADD expects 32 bits on the RHS, but RHS's VARREF 'mult' generates 16 bits.
                                       : ... note: In instance 'mac'
   17 |             out <= out + mult;
      |                        ^
%Error: Exiting due to 2 warning(s)
exit=1
```

**Substantive issue on LLM B:** `WIDTHEXPAND` on line 17. The 16-bit `mult` is added to a 32-bit accumulator without an explicit width cast. Detailed analysis is in Task 4 below.

---

## Task 3 — Simulate

### 3.1 Testbench

`codefest/cf04/hdl/mac_tb.v` applies the assignment's stimulus exactly:

1. `a = 3, b = 4` for **3 cycles**
2. assert `rst` for **1 cycle**
3. `a = -5, b = 2` for **2 cycles**

A pre-stimulus reset cycle is asserted to bring `out` to a known 0 before Phase 1 (not counted in the log). Inputs are driven in the half-cycle before each `posedge clk`, then `out` is sampled and printed after the edge.

### 3.2 Simulation output — `mac_llm_A.v`

```
---- Phase 1: a=3, b=4 for 3 cycles ----
cycle=1  rst=0  a=3  b=4  product=12  out=12
cycle=2  rst=0  a=3  b=4  product=12  out=24
cycle=3  rst=0  a=3  b=4  product=12  out=36
---- Phase 2: assert rst for 1 cycle ----
cycle=4  rst=1  a=3  b=4  product=12  out=0
---- Phase 3: a=-5, b=2 for 2 cycles ----
cycle=5  rst=0  a=-5  b=2  product=-10  out=-10
cycle=6  rst=0  a=-5  b=2  product=-10  out=-20
---- Done ----
mac_tb.v:78: $finish called at 66000 (1ps)
```

### 3.3 Simulation output — `mac_llm_B.v`

```
---- Phase 1: a=3, b=4 for 3 cycles ----
cycle=1  rst=0  a=3  b=4  product=12  out=12
cycle=2  rst=0  a=3  b=4  product=12  out=24
cycle=3  rst=0  a=3  b=4  product=12  out=36
---- Phase 2: assert rst for 1 cycle ----
cycle=4  rst=1  a=3  b=4  product=12  out=0
---- Phase 3: a=-5, b=2 for 2 cycles ----
cycle=5  rst=0  a=-5  b=2  product=-10  out=-10
cycle=6  rst=0  a=-5  b=2  product=-10  out=-20
---- Done ----
mac_tb.v:78: $finish called at 66000 (1ps)
```

### 3.4 Cycle-by-cycle expected vs. observed

| Cycle | rst | a  | b | a·b  | Expected `out` | A obs. | B obs. | Pass? |
|------:|:---:|---:|--:|-----:|---------------:|-------:|-------:|:-----:|
| 1     | 0   |  3 | 4 |  12  |  12            |  12    |  12    | ✅ |
| 2     | 0   |  3 | 4 |  12  |  24            |  24    |  24    | ✅ |
| 3     | 0   |  3 | 4 |  12  |  36            |  36    |  36    | ✅ |
| 4     | 1   |  3 | 4 |  —   |   0 (reset)    |   0    |   0    | ✅ |
| 5     | 0   | -5 | 2 | -10  | -10            | -10    | -10    | ✅ |
| 6     | 0   | -5 | 2 | -10  | -20            | -20    | -20    | ✅ |

Both LLMs produce a **bit-for-bit identical simulation trace** matching the spec.

---

## Task 4 — Review 

Three issues identified across the two files. Reviewed against the failure-mode hit-list in the handout (non-synthesizable constructs, wrong process type, sign-extension error, accumulator width mismatch, reset polarity error, missing port direction).

### Issue 1 — Implicit width-extension on the accumulator add (LLM B)

**Location:** `mac_llm_B.v`, line 17.

**(a) Quoted offending lines:**

```verilog
    // Internal multiplication result
    logic signed [15:0] mult;
    // Combinational multiply
    assign mult = a * b;
    // Sequential MAC operation
    always_ff @(posedge clk) begin
        if (rst) begin
            out <= 32'sd0;
        end else begin
            out <= out + mult;        // <-- line 17
        end
    end
```

**(b) Why this is wrong / ambiguous:**

`out` is 32 bits signed; `mult` is 16 bits signed. The expression `out + mult` mixes operand widths. SystemVerilog handles this via context-determined sizing: the result-context width (32 bits, from `out`) propagates back to the operands, and `mult` is sign-extended from 16 to 32 bits **only because it was declared `signed`**. The simulation behavior is correct today, but if a maintainer drops the `signed` keyword from `mult` or refactors the type, the sign-extension silently becomes a zero-extension and negative products go wrong with no compile-time error.

This is exactly the **sign-extension / accumulator width mismatch** failure mode called out in the handout. Verilator's lint flags it directly:

```
%Warning-WIDTHEXPAND: mac_llm_B.v:17:24: Operator ADD expects 32 bits on the RHS,
                     but RHS's VARREF 'mult' generates 16 bits.
   17 |             out <= out + mult;
      |                        ^
```

**(c) Corrected version:**

Sign-extend the product to the accumulator width explicitly so the add is unambiguously 32-bit-on-32-bit:

```verilog
    logic signed [15:0] mult;
    logic signed [31:0] mult_ext;

    assign mult     = a * b;
    assign mult_ext = 32'(mult);   // explicit signed cast to accumulator width

    always_ff @(posedge clk) begin
        if (rst)
            out <= 32'sd0;
        else
            out <= out + mult_ext;
    end
```

After this fix, Verilator runs clean (no `WIDTHEXPAND`).

---

### Issue 2 — Missing `` `default_nettype none `` (both files)

**Location:** top of file in both `mac_llm_A.v` and `mac_llm_B.v`.

**(a) Quoted offending lines:**

`mac_llm_A.v` opens directly with the module declaration:

```verilog
module mac (
    input  logic                clk,
    ...
```

`mac_llm_B.v` does the same:

```verilog
module mac (
    input  logic              clk,
    ...
```

Neither file contains a `` `default_nettype none `` directive.

**(b) Why this is a defect:**

By default, Verilog implicitly declares any undeclared identifier used in a port connection or expression as a 1-bit wire. A typo in a port or signal name does not raise an error — it produces a silent 1-bit floating net. For an 8-bit signed multiply that gets connected to a 1-bit floating net, the failure mode is a wrong simulation result with no warning. Standard SystemVerilog practice is to put `` `default_nettype none `` at the top of every RTL file so any undeclared identifier becomes a hard elaboration error.

Neither `iverilog -Wall` nor `verilator --lint-only -Wall` flagged this on these specific files (the LLMs happened not to introduce typos), but it is a defensive-coding gap both LLMs left open.

**(c) Corrected version:**

```verilog
`default_nettype none

module mac (
    input  logic                clk,
    input  logic                rst,
    input  logic signed [7:0]   a,
    input  logic signed [7:0]   b,
    output logic signed [31:0]  out
);
    ...
endmodule

`default_nettype wire
```

The trailing `` `default_nettype wire `` restores the default for any code that may follow this file in a compile unit.

---

### Issue 3 — Unnamed `always_ff` block (both files)

**Location:** `mac_llm_A.v` line ~31, `mac_llm_B.v` line ~13.

**(a) Quoted offending lines:**

LLM A:
```verilog
    always_ff @(posedge clk) begin
        if (rst)
            out <= 32'sd0;
        else
            out <= out + 32'(product);
    end
```

LLM B:
```verilog
    always_ff @(posedge clk) begin
        if (rst) begin
            out <= 32'sd0;
        end else begin
            out <= out + mult;
        end
    end
```

Neither block carries a label (`begin : <name>`).

**(b) Why this is suboptimal (not strictly wrong):**

Unlabeled procedural blocks are legal SystemVerilog and synthesize fine. However:
- Coverage tools (including the VCS-based flow used in ECE-593) report coverage hits keyed on block names. Unlabeled blocks show up as anonymous numeric identifiers, which makes triaging functional-coverage misses harder.
- Waveform viewers and assertion error messages reference the block by name. Anonymous blocks are harder to grep for in a large hierarchy.

A code-quality issue rather than a correctness bug, but it is the polish that distinguishes a verification-grade RTL file from a sketch.

**(c) Corrected version:**

```verilog
    always_ff @(posedge clk) begin : mac_accumulate
        if (rst)
            out <= 32'sd0;
        else
            out <= out + mult_ext;
    end
```

---

### Failure-mode hit-list (handout)

| Failure mode                       | LLM A          | LLM B          |
|------------------------------------|----------------|----------------|
| Non-synthesizable constructs (`initial`, `$display`, `#`, `fork/join`, dynamic alloc) | none ✅ | none ✅ |
| Wrong process type (`always @(*)` or plain `always` for FF logic)     | uses `always_ff` ✅ | uses `always_ff` ✅ |
| Sign-extension error (signed × signed without cast, treated as unsigned) | explicit cast `32'(product)` ✅ | implicit, lint-flagged ⚠️ (Issue 1) |
| Accumulator width mismatch (16-bit product into 32-bit reg without sign-ext) | safe ✅ | safe at runtime, brittle at source ⚠️ (Issue 1) |
| Reset polarity error (active-low for active-high spec or vice versa) | active-high sync ✅ | active-high sync ✅ |
| Missing port direction (no `input`/`output` keyword) | all ports directional ✅ | all ports directional ✅ |

The only failure-mode hit from the handout's list is the sign-extension/width issue on LLM B. Issues 2 and 3 are defensive-coding gaps both LLMs share but the failure-mode list does not explicitly itemize.

---

## Task 5 — Correct (`mac_correct.v`)

`codefest/cf04/hdl/mac_correct.v` is the corrected reference, incorporating all three fixes:

1. Explicit sign-extension of the product to 32 bits before the accumulator add (`32'(product)`).
2. `` `default_nettype none `` / `` `default_nettype wire `` wrapping.
3. Labeled `always_ff : mac_accumulate` block.

### 5.1 `iverilog` clean compile

```
$ iverilog -g2012 -Wall -o mac_correct_sim mac_correct.v mac_tb.v
exit=0
```

### 5.2 `verilator` clean lint

```
$ verilator --lint-only -Wall -Wno-DECLFILENAME mac_correct.v
exit=0
```

(`DECLFILENAME` suppressed — the filename is required by the assignment naming rule.)

### 5.3 Simulation log — `mac_correct.v` passing the testbench

```
$ vvp mac_correct_sim

---- Phase 1: a=3, b=4 for 3 cycles ----
cycle=1  rst=0  a=3  b=4  product=12  out=12
cycle=2  rst=0  a=3  b=4  product=12  out=24
cycle=3  rst=0  a=3  b=4  product=12  out=36
---- Phase 2: assert rst for 1 cycle ----
cycle=4  rst=1  a=3  b=4  product=12  out=0
---- Phase 3: a=-5, b=2 for 2 cycles ----
cycle=5  rst=0  a=-5  b=2  product=-10  out=-10
cycle=6  rst=0  a=-5  b=2  product=-10  out=-20
---- Done ----
mac_tb.v:78: $finish called at 66000 (1ps)
```

| Cycle | rst | a  | b | a·b  | Expected `out` | Observed `out` | Pass? |
|------:|:---:|---:|--:|-----:|---------------:|---------------:|:-----:|
| 1     | 0   |  3 | 4 |  12  |  12            |  12            | ✅ |
| 2     | 0   |  3 | 4 |  12  |  24            |  24            | ✅ |
| 3     | 0   |  3 | 4 |  12  |  36            |  36            | ✅ |
| 4     | 1   |  3 | 4 |  —   |   0 (reset)    |   0            | ✅ |
| 5     | 0   | -5 | 2 | -10  | -10            | -10            | ✅ |
| 6     | 0   | -5 | 2 | -10  | -20            | -20            | ✅ |

All six cycles match. `mac_correct.v` passes the cf04 testbench.

### 5.4 Yosys synthesis output 

```
$ yosys -p 'read_verilog -sv mac_correct.v; synth; stat'

2.26. Executing CHECK pass (checking for obvious problems).
Checking module mac...
Found and reported 0 problems.

3. Printing statistics.

=== mac ===

   Number of wires:               1039
   Number of wire bits:           1301
   Number of public wires:           5
   Number of public wire bits:      50
   Number of memories:               0
   Number of memory bits:            0
   Number of processes:              0
   Number of cells:               1091
     $_ANDNOT_                     351
     $_AND_                         61
     $_NAND_                        46
     $_NOR_                         33
     $_NOT_                         47
     $_ORNOT_                       18
     $_OR_                         133
     $_SDFF_PP0_                    32
     $_XNOR_                        97
     $_XOR_                        273
```

**Synthesis check:** 0 problems reported, 32 `$_SDFF_PP0_` cells (synchronous DFFs with positive-polarity reset — exactly matching the 32-bit accumulator with synchronous active-high reset), 0 latches inferred, 0 memories. The combinational logic count (~1059 cells) is the unrolled 8×8 signed array multiplier plus the 32-bit adder.

For reference, running the same yosys flow on `mac_llm_A.v` and `mac_llm_B.v` produces identical post-synthesis gate counts — yosys's optimizer collapses the source-level differences. The differences identified in this review are at the **source-quality and lint level**, not the post-synthesis level.

---

## Final summary

| Check                                      | LLM A                | LLM B                | `mac_correct.v` |
|--------------------------------------------|----------------------|----------------------|-----------------|
| `iverilog -g2012 -Wall`                    | ✅ clean             | ✅ clean             | ✅ clean        |
| `verilator --lint-only -Wall` (substantive)| ✅ none              | ⚠️ `WIDTHEXPAND` L17 | ✅ none         |
| Spec stimulus simulation                   | ✅ matches           | ✅ matches           | ✅ matches      |
| `always_ff` + sync active-high reset       | ✅                   | ✅                   | ✅              |
| No `initial` / `$display` / `#` delays     | ✅                   | ✅                   | ✅              |
| Yosys `synth; stat`                        | clean                | clean                | clean (0 problems, 32 SDFF) |

**Bottom line:** Both LLM outputs are functionally correct on the directed stimulus. LLM B has one source-quality defect (implicit width on the accumulator add) that strict lint catches and that LLM A avoids by using an explicit cast. `mac_correct.v` addresses that defect and two additional defensive-coding gaps shared by both LLMs.
