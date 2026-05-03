`default_nettype none

module fp16_multiplier (
    input  logic [15:0] a,
    input  logic [15:0] b,
    output logic [31:0] result
);

    logic        a_sign, b_sign;
    logic [4:0]  a_exp,  b_exp;
    logic [9:0]  a_mant, b_mant;

    assign a_sign = a[15];
    assign a_exp  = a[14:10];
    assign a_mant = a[9:0];

    assign b_sign = b[15];
    assign b_exp  = b[14:10];
    assign b_mant = b[9:0];

    logic a_is_zero, b_is_zero;
    assign a_is_zero = (a_exp == 5'd0) || (a_exp == 5'd31);
    assign b_is_zero = (b_exp == 5'd0) || (b_exp == 5'd31);

    logic any_zero;
    assign any_zero = a_is_zero || b_is_zero;

    logic prod_sign;
    assign prod_sign = a_sign ^ b_sign;

    logic [10:0] a_sig, b_sig;
    assign a_sig = {1'b1, a_mant};
    assign b_sig = {1'b1, b_mant};

    logic [21:0] mant_prod;
    assign mant_prod = a_sig * b_sig;

    logic prod_msb;
    assign prod_msb = mant_prod[21];

    logic signed [10:0] exp_fp32;
    assign exp_fp32 = $signed({1'b0, a_exp}) + $signed({1'b0, b_exp})
                    + 11'sd97 + (prod_msb ? 11'sd1 : 11'sd0);

    logic [22:0] fp32_mant;
    assign fp32_mant = prod_msb ? {mant_prod[20:0], 2'b00}
                                : {mant_prod[19:0], 3'b000};

    logic out_underflow, out_overflow;
    assign out_underflow = (exp_fp32 <= 11'sd0);
    assign out_overflow  = (exp_fp32 >= 11'sd255);

    logic force_zero;
    assign force_zero = any_zero || out_underflow || out_overflow;

    logic [7:0] exp_byte;
    assign exp_byte = exp_fp32[7:0];

    assign result = force_zero ? 32'h0000_0000
                               : {prod_sign, exp_byte, fp32_mant};

endmodule

`default_nettype wire
