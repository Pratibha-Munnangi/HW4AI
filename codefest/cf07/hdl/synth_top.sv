// =============================================================================
// File   : synth_top.sv
// Purpose: CF07 OpenLane 2 synthesis target for the QKT compute core.
//
// Single-file concatenation of the compute datapath for synthesis:
//   compute_core      -- NxN systolic array wrapper (synthesis top)
//   core_pe           -- single processing element (FP16 mul -> FP32 acc)
//   fp16_multiplier   -- combinational FP16 x FP16 -> FP32 multiplier
//   fp32_adder        -- combinational FP32 + FP32 -> FP32 adder
//
// The synthesis top module is `compute_core`. The AXI interface module
// (qkt_interface) is intentionally excluded -- CF07 synthesizes the compute
// core only.
//
// Array size is set by compute_core's N parameter (default N=4 => 4x4 = 16 PEs).
// =============================================================================

`default_nettype none

// -----------------------------------------------------------------------------
// compute_core -- NxN systolic array (SYNTHESIS TOP)
// -----------------------------------------------------------------------------
module compute_core #(
    parameter int N = 4,
    parameter int D = 4
) (
    input  logic                       clk,
    input  logic                       rst,
    input  logic                       en,
    input  logic [N*16-1:0]            q_in_bus,
    input  logic [N*16-1:0]            k_in_bus,
    output logic [N*N*32-1:0]          c_out_bus
);
    logic [15:0] q_row [N];
    logic [15:0] k_col [N];
    genvar gx;
    generate
        for (gx = 0; gx < N; gx++) begin : gen_io
            assign q_row[gx] = q_in_bus[gx*16 +: 16];
            assign k_col[gx] = k_in_bus[gx*16 +: 16];
        end
    endgenerate

    logic [15:0] a_wire   [N][N];
    logic [15:0] b_wire   [N][N];
    logic [15:0] a_fwd    [N][N];
    logic [15:0] b_fwd    [N][N];
    logic [31:0] acc_grid [N][N];
    genvar gi, gj;
    generate
        for (gi = 0; gi < N; gi++) begin : gen_row
            for (gj = 0; gj < N; gj++) begin : gen_col
                if (gj == 0)
                    assign a_wire[gi][gj] = q_row[gi];
                else
                    assign a_wire[gi][gj] = a_fwd[gi][gj-1];
                if (gi == 0)
                    assign b_wire[gi][gj] = k_col[gj];
                else
                    assign b_wire[gi][gj] = b_fwd[gi-1][gj];
                core_pe u_pe (
                    .clk     (clk),
                    .rst     (rst),
                    .en      (en),
                    .a_in    (a_wire[gi][gj]),
                    .b_in    (b_wire[gi][gj]),
                    .a_out   (a_fwd  [gi][gj]),
                    .b_out   (b_fwd  [gi][gj]),
                    .acc_out (acc_grid[gi][gj])
                );
            end : gen_col
        end : gen_row
    endgenerate

    genvar gi2, gj2;
    generate
        for (gi2 = 0; gi2 < N; gi2++) begin : gen_pack_row
            for (gj2 = 0; gj2 < N; gj2++) begin : gen_pack_col
                assign c_out_bus[(gi2*N + gj2)*32 +: 32] = acc_grid[gi2][gj2];
            end
        end
    endgenerate
endmodule

// -----------------------------------------------------------------------------
// core_pe -- single processing element
// -----------------------------------------------------------------------------
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

// -----------------------------------------------------------------------------
// fp16_multiplier -- combinational FP16 x FP16 -> FP32
// -----------------------------------------------------------------------------
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

// -----------------------------------------------------------------------------
// fp32_adder -- combinational FP32 + FP32 -> FP32
// -----------------------------------------------------------------------------
module fp32_adder (
    input  logic [31:0] a,
    input  logic [31:0] b,
    output logic [31:0] sum
);
    logic        a_sign, b_sign;
    logic [7:0]  a_exp,  b_exp;
    logic [22:0] a_mant, b_mant;

    assign a_sign = a[31];
    assign a_exp  = a[30:23];
    assign a_mant = a[22:0];

    assign b_sign = b[31];
    assign b_exp  = b[30:23];
    assign b_mant = b[22:0];

    logic a_is_zero, b_is_zero;
    assign a_is_zero = (a_exp == 8'd0) || (a_exp == 8'd255);
    assign b_is_zero = (b_exp == 8'd0) || (b_exp == 8'd255);

    logic        ea_sign, eb_sign;
    logic [7:0]  ea_exp,  eb_exp;
    logic [23:0] ea_sig,  eb_sig;

    assign ea_sign = a_is_zero ? 1'b0  : a_sign;
    assign ea_exp  = a_is_zero ? 8'd0  : a_exp;
    assign ea_sig  = a_is_zero ? 24'd0 : {1'b1, a_mant};

    assign eb_sign = b_is_zero ? 1'b0  : b_sign;
    assign eb_exp  = b_is_zero ? 8'd0  : b_exp;
    assign eb_sig  = b_is_zero ? 24'd0 : {1'b1, b_mant};

    logic a_is_bigger;
    assign a_is_bigger = (ea_exp >  eb_exp) ||
                        ((ea_exp == eb_exp) && (ea_sig >= eb_sig));

    logic        big_sign, sml_sign;
    logic [7:0]  big_exp;
    logic [26:0] big_sig_ext, sml_sig_ext;
    logic [7:0]  exp_diff;

    assign big_sign    = a_is_bigger ? ea_sign : eb_sign;
    assign big_exp     = a_is_bigger ? ea_exp  : eb_exp;
    assign big_sig_ext = a_is_bigger ? {ea_sig, 3'b000} : {eb_sig, 3'b000};
    assign sml_sign    = a_is_bigger ? eb_sign : ea_sign;
    assign sml_sig_ext = a_is_bigger ? {eb_sig, 3'b000} : {ea_sig, 3'b000};
    assign exp_diff    = a_is_bigger ? (ea_exp - eb_exp) : (eb_exp - ea_exp);

    logic        diff_too_big;
    logic [26:0] sml_aligned_pre;
    logic [26:0] mask;
    logic        sticky_shift;

    assign diff_too_big    = (exp_diff >= 8'd27);
    assign mask            = diff_too_big ? 27'd0 : ((27'd1 << exp_diff) - 27'd1);
    assign sticky_shift    = diff_too_big ? (|sml_sig_ext)
                                          : (|(sml_sig_ext & mask));
    assign sml_aligned_pre = diff_too_big ? 27'd0 : (sml_sig_ext >> exp_diff);

    logic [26:0] sml_aligned_sticky;
    assign sml_aligned_sticky = sml_aligned_pre | {26'd0, sticky_shift};

    logic        same_sign;
    logic [27:0] raw_result;

    assign same_sign  = (big_sign == sml_sign);
    assign raw_result = same_sign
                      ? ({1'b0, big_sig_ext} + {1'b0, sml_aligned_sticky})
                      : ({1'b0, big_sig_ext} - {1'b0, sml_aligned_sticky});

    logic [26:0] raw_low;
    assign raw_low = raw_result[26:0];

    logic [4:0] lz;
    always_comb begin
        casez (raw_low)
            27'b1??????????????????????????: lz = 5'd0;
            27'b01?????????????????????????: lz = 5'd1;
            27'b001????????????????????????: lz = 5'd2;
            27'b0001???????????????????????: lz = 5'd3;
            27'b00001??????????????????????: lz = 5'd4;
            27'b000001?????????????????????: lz = 5'd5;
            27'b0000001????????????????????: lz = 5'd6;
            27'b00000001???????????????????: lz = 5'd7;
            27'b000000001??????????????????: lz = 5'd8;
            27'b0000000001?????????????????: lz = 5'd9;
            27'b00000000001????????????????: lz = 5'd10;
            27'b000000000001???????????????: lz = 5'd11;
            27'b0000000000001??????????????: lz = 5'd12;
            27'b00000000000001?????????????: lz = 5'd13;
            27'b000000000000001????????????: lz = 5'd14;
            27'b0000000000000001???????????: lz = 5'd15;
            27'b00000000000000001??????????: lz = 5'd16;
            27'b000000000000000001?????????: lz = 5'd17;
            27'b0000000000000000001????????: lz = 5'd18;
            27'b00000000000000000001???????: lz = 5'd19;
            27'b000000000000000000001??????: lz = 5'd20;
            27'b0000000000000000000001?????: lz = 5'd21;
            27'b00000000000000000000001????: lz = 5'd22;
            27'b000000000000000000000001???: lz = 5'd23;
            27'b0000000000000000000000001??: lz = 5'd24;
            27'b00000000000000000000000001?: lz = 5'd25;
            27'b000000000000000000000000001: lz = 5'd26;
            default:                          lz = 5'd27;
        endcase
    end

    logic carry_out;
    logic all_zero;
    assign carry_out = raw_result[27];
    assign all_zero  = (raw_low == 27'd0);

    logic [27:0] rsh_sig;
    assign rsh_sig = {1'b0, raw_result[27:1]} | {27'd0, raw_result[0]};

    logic [26:0] lsh_low;
    assign lsh_low = raw_low << lz;
    logic [27:0] lsh_sig;
    assign lsh_sig = {1'b0, lsh_low};

    logic [27:0] norm_sig;
    logic [8:0]  norm_exp;
    logic        sub_underflow;

    assign sub_underflow = ({1'b0, big_exp} <= {4'd0, lz});

    assign norm_sig = carry_out ? rsh_sig
                    : all_zero  ? 28'd0
                                : lsh_sig;

    assign norm_exp = carry_out      ? ({1'b0, big_exp} + 9'd1)
                    : all_zero       ? 9'd0
                    : sub_underflow  ? 9'd0
                                     : ({1'b0, big_exp} - {4'd0, lz});

    logic guard, round_b, sticky;
    logic [22:0] mant_pre;

    assign guard    = norm_sig[2];
    assign round_b  = norm_sig[1];
    assign sticky   = norm_sig[0];
    assign mant_pre = norm_sig[25:3];

    logic round_up;
    assign round_up = guard & (round_b | sticky | mant_pre[0]);

    logic [23:0] mant_added;
    assign mant_added = {1'b0, mant_pre} + (round_up ? 24'd1 : 24'd0);

    logic        round_carry;
    assign round_carry = mant_added[23];

    logic [22:0] mant_final;
    logic [8:0]  exp_final;
    assign mant_final = round_carry ? mant_added[23:1] : mant_added[22:0];
    assign exp_final  = round_carry ? (norm_exp + 9'd1) : norm_exp;

    logic out_underflow, out_overflow;
    assign out_underflow = (exp_final == 9'd0) || exp_final[8];
    assign out_overflow  = (exp_final >= 9'd255);

    logic both_zero, only_a_zero, only_b_zero, force_zero;
    assign both_zero   = a_is_zero && b_is_zero;
    assign only_a_zero = a_is_zero && !b_is_zero;
    assign only_b_zero = b_is_zero && !a_is_zero;
    assign force_zero  = both_zero || all_zero || out_underflow || out_overflow;

    logic [31:0] normal_sum;
    assign normal_sum = {big_sign, exp_final[7:0], mant_final};

    assign sum = force_zero  ? 32'h0000_0000
              : only_a_zero ? {b_sign, b_exp, b_mant}
              : only_b_zero ? {a_sign, a_exp, a_mant}
                            : normal_sum;
endmodule

`default_nettype wire
