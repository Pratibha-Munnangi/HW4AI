// =============================================================================
// File   : fp32_adder_pipelined.sv
// Module : fp32_adder_pipelined
//
// 3-stage pipelined IEEE-754 binary32 (FP32) adder for the M4 architectural
// pass of the QK^T accelerator.
//
// Replaces the original combinational fp32_adder.sv (M3 V5) whose ~58-level
// barrel-shifter chain set the critical path at ~24 ns post-PnR (typical
// corner). Splitting that chain across three balanced pipeline stages cuts
// the per-stage logic depth to ~17-20 levels each, enabling an 8 ns clock
// target.
//
// Pipeline structure
// ------------------
//   S1 (combinational, then register):
//     - Decompose a, b into sign/exp/mantissa
//     - FTZ-classify subnormal / NaN inputs as zero
//     - Determine larger-magnitude operand
//     - Compute exponent difference
//     - ALIGN-SHIFT: variable right-shift of smaller significand
//       (this is the FIRST big barrel shifter)
//     - Compute sticky from shifted-out bits
//
//   S2 (combinational, then register):
//     - 28-bit add or subtract of aligned significands (sign-magnitude form)
//     - Leading-zero count over 27-bit raw sum
//     - NORMALIZE-SHIFT: variable left-shift by LZC
//       (this is the SECOND big barrel shifter)
//     - Carry-out vs left-shift vs zero mux
//     - Adjusted exponent computation
//
//   S3 (combinational, then register output):
//     - Round-to-nearest-even on guard/round/sticky bits
//     - Round-up carry propagation
//     - Underflow / overflow detection
//     - FTZ output handling: special-case pass-through when one operand was
//       zero, both-zero, or normalize-to-zero
//
// Latency: 3 clock cycles from valid_in to valid_out (registered output).
// Throughput: 1 result per cycle (true pipeline).
//
// Bugfix carried forward from M3 V5
// ---------------------------------
//   The original combinational fp32_adder.sv flushed legitimate results to
//   zero when same-sign equal-magnitude operands collapsed the entire 27-bit
//   raw mantissa-sum into the carry-out bit (e.g. 0.03125 + 0.03125 = 0.0625
//   in the synth notes example). In that case `raw_low` is all-zero but
//   `carry_out` is 1, so `force_zero` should NOT fire. The gate is:
//
//     all_zero_real = all_zero && !carry_out
//
//   and `force_zero` uses `all_zero_real` rather than the raw `all_zero`.
//
// Interface
// ---------
//   clk, rst        : synchronous active-high reset
//   valid_in        : assert with valid (a, b) inputs on a given cycle
//   a, b            : FP32 operands
//   valid_out       : asserts 3 cycles after the corresponding valid_in
//   sum             : FP32 result, valid only when valid_out is high
//
// =============================================================================

`default_nettype none

module fp32_adder_pipelined (
    input  logic        clk,
    input  logic        rst,
    input  logic        valid_in,
    input  logic [31:0] a,
    input  logic [31:0] b,
    output logic        valid_out,
    output logic [31:0] sum
);

    // =========================================================================
    // STAGE 1: Decompose + classify + align-shift
    // =========================================================================

    // ---- Decompose ----
    logic        a_sign_s1, b_sign_s1;
    logic [7:0]  a_exp_s1,  b_exp_s1;
    logic [22:0] a_mant_s1, b_mant_s1;

    assign a_sign_s1 = a[31];
    assign a_exp_s1  = a[30:23];
    assign a_mant_s1 = a[22:0];

    assign b_sign_s1 = b[31];
    assign b_exp_s1  = b[30:23];
    assign b_mant_s1 = b[22:0];

    // ---- FTZ on inputs (treat subnormals and NaN/Inf as zero) ----
    logic a_is_zero_s1, b_is_zero_s1;
    assign a_is_zero_s1 = (a_exp_s1 == 8'd0) || (a_exp_s1 == 8'd255);
    assign b_is_zero_s1 = (b_exp_s1 == 8'd0) || (b_exp_s1 == 8'd255);

    logic        ea_sign, eb_sign;
    logic [7:0]  ea_exp,  eb_exp;
    logic [23:0] ea_sig,  eb_sig;

    assign ea_sign = a_is_zero_s1 ? 1'b0  : a_sign_s1;
    assign ea_exp  = a_is_zero_s1 ? 8'd0  : a_exp_s1;
    assign ea_sig  = a_is_zero_s1 ? 24'd0 : {1'b1, a_mant_s1};

    assign eb_sign = b_is_zero_s1 ? 1'b0  : b_sign_s1;
    assign eb_exp  = b_is_zero_s1 ? 8'd0  : b_exp_s1;
    assign eb_sig  = b_is_zero_s1 ? 24'd0 : {1'b1, b_mant_s1};

    // ---- Determine the larger-magnitude operand ----
    logic a_is_bigger;
    assign a_is_bigger = (ea_exp >  eb_exp) ||
                        ((ea_exp == eb_exp) && (ea_sig >= eb_sig));

    logic        big_sign_s1, sml_sign_s1;
    logic [7:0]  big_exp_s1;
    logic [26:0] big_sig_ext_s1, sml_sig_ext;
    logic [7:0]  exp_diff;

    assign big_sign_s1    = a_is_bigger ? ea_sign : eb_sign;
    assign big_exp_s1     = a_is_bigger ? ea_exp  : eb_exp;
    assign big_sig_ext_s1 = a_is_bigger ? {ea_sig, 3'b000} : {eb_sig, 3'b000};
    assign sml_sign_s1    = a_is_bigger ? eb_sign : ea_sign;
    assign sml_sig_ext    = a_is_bigger ? {eb_sig, 3'b000} : {ea_sig, 3'b000};
    assign exp_diff       = a_is_bigger ? (ea_exp - eb_exp) : (eb_exp - ea_exp);

    // ---- Align smaller significand (FIRST big barrel shifter) ----
    logic        diff_too_big;
    logic [26:0] sml_aligned_pre;
    logic [26:0] mask;
    logic        sticky_shift;

    assign diff_too_big    = (exp_diff >= 8'd27);
    assign mask            = diff_too_big ? 27'd0 : ((27'd1 << exp_diff) - 27'd1);
    assign sticky_shift    = diff_too_big ? (|sml_sig_ext)
                                          : (|(sml_sig_ext & mask));
    assign sml_aligned_pre = diff_too_big ? 27'd0 : (sml_sig_ext >> exp_diff);

    logic [26:0] sml_aligned_sticky_s1;
    assign sml_aligned_sticky_s1 = sml_aligned_pre | {26'd0, sticky_shift};

    // ---- S1 -> S2 pipeline registers ----
    logic        valid_s2;
    logic        big_sign_s2, sml_sign_s2;
    logic [7:0]  big_exp_s2;
    logic [26:0] big_sig_ext_s2, sml_aligned_sticky_s2;
    logic        a_is_zero_s2, b_is_zero_s2;
    logic [31:0] a_s2, b_s2;   // passthrough for special-case output

    always_ff @(posedge clk) begin
        if (rst) begin
            valid_s2              <= 1'b0;
            big_sign_s2           <= 1'b0;
            big_exp_s2            <= 8'd0;
            big_sig_ext_s2        <= 27'd0;
            sml_sign_s2           <= 1'b0;
            sml_aligned_sticky_s2 <= 27'd0;
            a_is_zero_s2          <= 1'b0;
            b_is_zero_s2          <= 1'b0;
            a_s2                  <= 32'd0;
            b_s2                  <= 32'd0;
        end else begin
            valid_s2              <= valid_in;
            big_sign_s2           <= big_sign_s1;
            big_exp_s2            <= big_exp_s1;
            big_sig_ext_s2        <= big_sig_ext_s1;
            sml_sign_s2           <= sml_sign_s1;
            sml_aligned_sticky_s2 <= sml_aligned_sticky_s1;
            a_is_zero_s2          <= a_is_zero_s1;
            b_is_zero_s2          <= b_is_zero_s1;
            a_s2                  <= a;
            b_s2                  <= b;
        end
    end

    // =========================================================================
    // STAGE 2: Add/subtract + LZC + normalize-shift
    // =========================================================================

    // ---- Add or subtract magnitudes ----
    logic        same_sign_s2;
    logic [27:0] raw_result_s2;

    assign same_sign_s2  = (big_sign_s2 == sml_sign_s2);
    assign raw_result_s2 = same_sign_s2
                         ? ({1'b0, big_sig_ext_s2} + {1'b0, sml_aligned_sticky_s2})
                         : ({1'b0, big_sig_ext_s2} - {1'b0, sml_aligned_sticky_s2});

    // ---- Leading-zero count over bits [26:0] ----
    logic [26:0] raw_low_s2;
    assign raw_low_s2 = raw_result_s2[26:0];

    logic [4:0] lz_s2;
    always_comb begin
        casez (raw_low_s2)
            27'b1??????????????????????????: lz_s2 = 5'd0;
            27'b01?????????????????????????: lz_s2 = 5'd1;
            27'b001????????????????????????: lz_s2 = 5'd2;
            27'b0001???????????????????????: lz_s2 = 5'd3;
            27'b00001??????????????????????: lz_s2 = 5'd4;
            27'b000001?????????????????????: lz_s2 = 5'd5;
            27'b0000001????????????????????: lz_s2 = 5'd6;
            27'b00000001???????????????????: lz_s2 = 5'd7;
            27'b000000001??????????????????: lz_s2 = 5'd8;
            27'b0000000001?????????????????: lz_s2 = 5'd9;
            27'b00000000001????????????????: lz_s2 = 5'd10;
            27'b000000000001???????????????: lz_s2 = 5'd11;
            27'b0000000000001??????????????: lz_s2 = 5'd12;
            27'b00000000000001?????????????: lz_s2 = 5'd13;
            27'b000000000000001????????????: lz_s2 = 5'd14;
            27'b0000000000000001???????????: lz_s2 = 5'd15;
            27'b00000000000000001??????????: lz_s2 = 5'd16;
            27'b000000000000000001?????????: lz_s2 = 5'd17;
            27'b0000000000000000001????????: lz_s2 = 5'd18;
            27'b00000000000000000001???????: lz_s2 = 5'd19;
            27'b000000000000000000001??????: lz_s2 = 5'd20;
            27'b0000000000000000000001?????: lz_s2 = 5'd21;
            27'b00000000000000000000001????: lz_s2 = 5'd22;
            27'b000000000000000000000001???: lz_s2 = 5'd23;
            27'b0000000000000000000000001??: lz_s2 = 5'd24;
            27'b00000000000000000000000001?: lz_s2 = 5'd25;
            27'b000000000000000000000000001: lz_s2 = 5'd26;
            default:                          lz_s2 = 5'd27;
        endcase
    end

    // ---- Normalize: three branches (carry-out / all-zero / left-shift) ----
    logic carry_out_s2;
    logic all_zero_s2;
    assign carry_out_s2 = raw_result_s2[27];
    assign all_zero_s2  = (raw_low_s2 == 27'd0);

    // Right-shift result for carry-out branch (sticky-OR the shifted bit)
    logic [27:0] rsh_sig;
    assign rsh_sig = {1'b0, raw_result_s2[27:1]} | {27'd0, raw_result_s2[0]};

    // Left-shift result for renormalization branch (SECOND big barrel shifter)
    logic [26:0] lsh_low;
    assign lsh_low = raw_low_s2 << lz_s2;
    logic [27:0] lsh_sig;
    assign lsh_sig = {1'b0, lsh_low};

    // Choose normalized significand and exponent
    logic [27:0] norm_sig_s2;
    logic [8:0]  norm_exp_s2;
    logic        sub_underflow_s2;

    assign sub_underflow_s2 = ({1'b0, big_exp_s2} <= {4'd0, lz_s2});

    assign norm_sig_s2 = carry_out_s2 ? rsh_sig
                       : all_zero_s2  ? 28'd0
                                      : lsh_sig;

    assign norm_exp_s2 = carry_out_s2      ? ({1'b0, big_exp_s2} + 9'd1)
                       : all_zero_s2       ? 9'd0
                       : sub_underflow_s2  ? 9'd0
                                           : ({1'b0, big_exp_s2} - {4'd0, lz_s2});

    // V5 BUGFIX: gate all_zero on !carry_out so force_zero doesn't flush
    // legitimate carry-out results to zero.
    logic all_zero_real_s2;
    assign all_zero_real_s2 = all_zero_s2 && !carry_out_s2;

    // ---- S2 -> S3 pipeline registers ----
    logic        valid_s3;
    logic        big_sign_s3;
    logic [27:0] norm_sig_s3;
    logic [8:0]  norm_exp_s3;
    logic        all_zero_real_s3;
    logic        a_is_zero_s3, b_is_zero_s3;
    logic [31:0] a_s3, b_s3;

    always_ff @(posedge clk) begin
        if (rst) begin
            valid_s3         <= 1'b0;
            big_sign_s3      <= 1'b0;
            norm_sig_s3      <= 28'd0;
            norm_exp_s3      <= 9'd0;
            all_zero_real_s3 <= 1'b0;
            a_is_zero_s3     <= 1'b0;
            b_is_zero_s3     <= 1'b0;
            a_s3             <= 32'd0;
            b_s3             <= 32'd0;
        end else begin
            valid_s3         <= valid_s2;
            big_sign_s3      <= big_sign_s2;
            norm_sig_s3      <= norm_sig_s2;
            norm_exp_s3      <= norm_exp_s2;
            all_zero_real_s3 <= all_zero_real_s2;
            a_is_zero_s3     <= a_is_zero_s2;
            b_is_zero_s3     <= b_is_zero_s2;
            a_s3             <= a_s2;
            b_s3             <= b_s2;
        end
    end

    // =========================================================================
    // STAGE 3: RNE round + output handling
    // =========================================================================

    // ---- RNE rounding ----
    logic guard, round_b, sticky;
    logic [22:0] mant_pre;

    assign guard    = norm_sig_s3[2];
    assign round_b  = norm_sig_s3[1];
    assign sticky   = norm_sig_s3[0];
    assign mant_pre = norm_sig_s3[25:3];

    logic round_up;
    assign round_up = guard & (round_b | sticky | mant_pre[0]);

    logic [23:0] mant_added;
    assign mant_added = {1'b0, mant_pre} + (round_up ? 24'd1 : 24'd0);

    logic        round_carry;
    assign round_carry = mant_added[23];

    logic [22:0] mant_final;
    logic [8:0]  exp_final;
    assign mant_final = round_carry ? mant_added[23:1] : mant_added[22:0];
    assign exp_final  = round_carry ? (norm_exp_s3 + 9'd1) : norm_exp_s3;

    // ---- Output handling ----
    logic out_underflow, out_overflow;
    assign out_underflow = (exp_final == 9'd0) || exp_final[8];
    assign out_overflow  = (exp_final >= 9'd255);

    logic both_zero, only_a_zero, only_b_zero, force_zero;
    assign both_zero   = a_is_zero_s3 && b_is_zero_s3;
    assign only_a_zero = a_is_zero_s3 && !b_is_zero_s3;
    assign only_b_zero = b_is_zero_s3 && !a_is_zero_s3;
    assign force_zero  = both_zero || all_zero_real_s3 || out_underflow || out_overflow;

    logic [31:0] normal_sum;
    assign normal_sum = {big_sign_s3, exp_final[7:0], mant_final};

    logic [31:0] sum_pre_reg;
    assign sum_pre_reg = force_zero   ? 32'h0000_0000
                       : only_a_zero  ? {b_s3[31], b_s3[30:23], b_s3[22:0]}
                       : only_b_zero  ? {a_s3[31], a_s3[30:23], a_s3[22:0]}
                                      : normal_sum;

    // Register S3 output for clean pipeline timing (gives S3 its own clock-to-Q)
    always_ff @(posedge clk) begin
        if (rst) begin
            sum       <= 32'd0;
            valid_out <= 1'b0;
        end else begin
            sum       <= sum_pre_reg;
            valid_out <= valid_s3;
        end
    end

endmodule

`default_nettype wire
