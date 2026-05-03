`default_nettype none

module core_pe (
    input  logic        clk,
    input  logic        rst,
    input  logic        en,
    input  logic [15:0] a_in,
    input  logic [15:0] b_in,
    output logic [15:0] a_out,
    output logic [15:0] b_out,
    output logic [31:0] acc_out
);

    logic [31:0] product_fp32;

    fp16_multiplier u_mul (
        .a      (a_in),
        .b      (b_in),
        .result (product_fp32)
    );

    logic [31:0] acc_next;

    fp32_adder u_add (
        .a   (acc_out),
        .b   (product_fp32),
        .sum (acc_next)
    );

    always_ff @(posedge clk) begin : pe_seq
        if (rst) begin
            acc_out <= 32'h0000_0000;
            a_out   <= 16'h0000;
            b_out   <= 16'h0000;
        end else begin
            a_out <= a_in;
            b_out <= b_in;
            if (en)
                acc_out <= acc_next;
        end
    end

endmodule

`default_nettype wire
