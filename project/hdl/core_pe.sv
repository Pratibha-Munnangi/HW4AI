// =============================================================================
// File        : core_pe.sv
// Module      : core_pe
// Description : Single processing element (PE) for the QKT systolic MAC
//               array — top-level module of the project compute core.
//               One element of the 16x16 grid in the M1 design.
//
// Function    : On each clock with `en=1`, computes a*b and adds it to an
//               internal accumulator. With `en=0` the accumulator holds.
//               Synchronous active-high reset clears the accumulator.
//
// Systolic-array integration notes
// --------------------------------
// In the full QKT array, neighboring PEs forward their `a` (row) and `b`
// (column) inputs after each cycle. To support that, this PE registers
// its inputs and exposes them as `a_out` / `b_out` so the next PE in the
// row/column can take them with one cycle of skew. This is the standard
// output-stationary systolic arrangement.
//
// Parameters
// ----------
//   A_WIDTH   : bit width of `a` operand (signed). Default 8 (INT8).
//   B_WIDTH   : bit width of `b` operand (signed). Default 8 (INT8).
//   ACC_WIDTH : bit width of accumulator. Default 32 — large enough to
//               accumulate up to ~133K worst-case INT8 products without
//               overflow (verified by the cf04 overflow test on mac_correct).
//
// Constraints : Synthesizable SystemVerilog. No initial blocks, no $display,
//               no delays. Uses always_ff. Synchronous active-high reset.
// =============================================================================

`default_nettype none

module core_pe #(
    parameter int A_WIDTH   = 8,
    parameter int B_WIDTH   = 8,
    parameter int ACC_WIDTH = 32
) (
    input  logic                          clk,
    input  logic                          rst,        // sync, active-high
    input  logic                          en,         // accumulate enable
    input  logic signed [A_WIDTH-1:0]     a_in,       // row input
    input  logic signed [B_WIDTH-1:0]     b_in,       // column input
    output logic signed [A_WIDTH-1:0]     a_out,      // forwarded to next PE in row
    output logic signed [B_WIDTH-1:0]     b_out,      // forwarded to next PE in column
    output logic signed [ACC_WIDTH-1:0]   acc_out     // local accumulator value
);

    // Local product. The signed product fits in A_WIDTH + B_WIDTH bits.
    localparam int PROD_WIDTH = A_WIDTH + B_WIDTH;

    logic signed [PROD_WIDTH-1:0] product;
    assign product = a_in * b_in;

    // Sign-extend the product to the full accumulator width before the add.
    logic signed [ACC_WIDTH-1:0] product_ext;
    assign product_ext = ACC_WIDTH'(product);

    // Internal accumulator + input forwarding registers.
    always_ff @(posedge clk) begin : pe_seq
        if (rst) begin
            acc_out <= '0;
            a_out   <= '0;
            b_out   <= '0;
        end else begin
            // Always forward inputs (so the array continues to advance even
            // when this PE is gated off).
            a_out <= a_in;
            b_out <= b_in;
            // Conditionally accumulate.
            if (en)
                acc_out <= acc_out + product_ext;
        end
    end

endmodule

`default_nettype wire
