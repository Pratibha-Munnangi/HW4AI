// =============================================================================
// File        : mac_correct.v
// Module      : mac
// Description : Reference 8x8 signed Multiply-Accumulate, 32-bit signed
//               accumulator, synchronous active-high reset.
//
// This is the corrected version informed by the review of mac_llm_A.v and
// mac_llm_B.v. Changes vs. the LLM outputs:
//   - Explicit 32-bit signed sign-extension of the product before the add
//     (eliminates Verilator WIDTHEXPAND warning seen on LLM B).
//   - `default_nettype none` to catch typos at elaboration.
//   - Named `always_ff` block for waveform / coverage clarity.
// =============================================================================

`default_nettype none

module mac (
    input  logic                clk,   // clock
    input  logic                rst,   // synchronous, active-high reset
    input  logic signed [7:0]   a,     // 8-bit signed operand
    input  logic signed [7:0]   b,     // 8-bit signed operand
    output logic signed [31:0]  out    // 32-bit signed accumulator
);

    // Signed 8x8 -> 16-bit signed product
    logic signed [15:0] product;
    assign product = a * b;

    // Sign-extend product to full accumulator width before the add so the
    // RHS of `+` is unambiguously 32 bits signed (no implicit widening).
    logic signed [31:0] product_ext;
    assign product_ext = 32'(product);

    always_ff @(posedge clk) begin : mac_accumulate
        if (rst)
            out <= 32'sd0;
        else
            out <= out + product_ext;
    end

endmodule

`default_nettype wire
