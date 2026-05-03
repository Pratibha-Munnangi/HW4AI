`default_nettype none

module fp32_adder (
    input  logic [31:0] a,
    input  logic [31:0] b,
    output logic [31:0] sum
);

    // ---------- Decompose ----------
    logic        a_sign, b_sign;
    logic [7:0]  a_exp,  b_exp;
    logic [22:0] a_mant, b_mant;

    assign a_sign = a[31];
    assign a_exp  = a[30:23];
    assign a_mant = a[22:0];

    assign b_sign = b[31];
    assign b_exp  = b[30:23];
    assign b_mant = b[22:0];

    // ---------- FTZ on inputs ----------
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

    // ---------- Determine the larger-magnitude operand ----------
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

    // ---------- Align smaller significand with sticky preservation ----------
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

    // ---------- Add or subtract magnitudes ----------
    logic        same_sign;
    logic [27:0] raw_result;

    assign same_sign  = (big_sign == sml_sign);
    assign raw_result = same_sign
                      ? ({1'b0, big_sig_ext} + {1'b0, sml_aligned_sticky})
                      : ({1'b0, big_sig_ext} - {1'b0, sml_aligned_sticky});

    // ---------- Leading-zero count over bits [26:0] ----------
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

    // ---------- Normalize ----------
    // Three branches: carry-out (right shift), all-zero, or left-shift by lz.
    logic carry_out;
    logic all_zero;
    assign carry_out = raw_result[27];
    assign all_zero  = (raw_low == 27'd0);

    // Right-shift result for carry-out branch (also OR'd sticky from shifted-out bit).
    logic [27:0] rsh_sig;
    assign rsh_sig = {1'b0, raw_result[27:1]} | {27'd0, raw_result[0]};

    // Left-shift result for renormalization branch.
    logic [26:0] lsh_low;
    assign lsh_low = raw_low << lz;
    logic [27:0] lsh_sig;
    assign lsh_sig = {1'b0, lsh_low};

    // Choose normalized significand and exponent.
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

    // ---------- RNE rounding ----------
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

    // ---------- Output handling ----------
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
