`timescale 1ns/1ps
`default_nettype none

module tb_compute_core;

    localparam int N = 4;
    localparam int D = 4;

    localparam real REL_TOL = 0.0009765625;
    localparam real ABS_TOL = 0.000001;

    localparam int CLK_PERIOD = 10;

    logic clk;
    logic rst;
    logic en;

    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    logic [N*16-1:0] q_in_bus;
    logic [N*16-1:0] k_in_bus;
    logic [N*N*32-1:0] c_out_bus;

    // Per-row/col handles for stimulus driving and result reads.
    logic [15:0] q_in [N];
    logic [15:0] k_in [N];
    logic [31:0] c_out [N][N];

    // Pack stimulus into the bus.
    integer pack_i, pack_j;
    always_comb begin
        for (pack_i = 0; pack_i < N; pack_i = pack_i + 1) begin
            q_in_bus[pack_i*16 +: 16] = q_in[pack_i];
            k_in_bus[pack_i*16 +: 16] = k_in[pack_i];
        end
        for (pack_i = 0; pack_i < N; pack_i = pack_i + 1) begin
            for (pack_j = 0; pack_j < N; pack_j = pack_j + 1) begin
                c_out[pack_i][pack_j] = c_out_bus[(pack_i*N + pack_j)*32 +: 32];
            end
        end
    end

    compute_core #(
        .N (N),
        .D (D)
    ) dut (
        .clk       (clk),
        .rst       (rst),
        .en        (en),
        .q_in_bus  (q_in_bus),
        .k_in_bus  (k_in_bus),
        .c_out_bus (c_out_bus)
    );

    logic [15:0] q_mem [N*D];
    logic [15:0] k_mem [N*D];
    logic [31:0] ref_mem [N*N];

    integer cycle_count;
    integer fail_count;
    integer pass_count;

    // Manual IEEE 754 binary32 -> real conversion (no $bitstoshortreal,
    // which Icarus 12 lacks). Handles zero, normals; treats subnormals,
    // Inf, NaN as zero (consistent with the FTZ policy in the design).
    function automatic real fp32_to_real(input logic [31:0] x);
        logic        s;
        logic [7:0]  e;
        logic [22:0] m;
        integer      true_exp;
        real         frac, mag, val, p;
        integer      i, k;
        begin
            s = x[31];
            e = x[30:23];
            m = x[22:0];

            if (e == 8'd0 || e == 8'd255) begin
                return 0.0;
            end

            // Build 1.mantissa as a real in [1.0, 2.0).
            frac = 1.0;
            p    = 0.5;          // 2^-1
            for (i = 22; i >= 0; i = i - 1) begin
                if (m[i])
                    frac = frac + p;
                p = p / 2.0;
            end

            // 2^(e-127) via shift, no $pow.
            true_exp = e - 127;
            mag = frac;
            if (true_exp >= 0) begin
                for (k = 0; k < true_exp; k = k + 1) mag = mag * 2.0;
            end else begin
                for (k = 0; k < -true_exp; k = k + 1) mag = mag / 2.0;
            end
            val = s ? -mag : mag;
            return val;
        end
    endfunction

    function automatic real rabs(input real x);
        return (x < 0.0) ? -x : x;
    endfunction

    initial begin : main_test
        integer i, j, t;
        integer t_max;
        real    hw_r, ref_r, err, thresh;
        logic [31:0] hw_bits;
        logic [31:0] ref_bits;

        $dumpfile("sim/tb_compute_core.vcd");
        $dumpvars(0, tb_compute_core);

        $display("============================================================");
        $display(" tb_compute_core : N=%0d, D=%0d", N, D);
        $display(" REL_TOL = %g    ABS_TOL = %g", REL_TOL, ABS_TOL);
        $display("============================================================");

        $readmemh("sim/q_hex.mem",   q_mem);
        $readmemh("sim/k_hex.mem",   k_mem);
        $readmemh("sim/ref_hex.mem", ref_mem);

        en = 1'b0;
        for (i = 0; i < N; i++) begin
            q_in[i] = 16'h0000;
            k_in[i] = 16'h0000;
        end

        rst = 1'b1;
        @(posedge clk); #1;
        @(posedge clk); #1;
        rst = 1'b0;

        // Total cycles where en must be high so that PE[N-1][N-1] receives
        // its last operand (Q[N-1, D-1], K[N-1, D-1]):
        //   that pair arrives at PE[N-1][N-1] at cycle 2*(N-1) + (D-1).
        // West/north edges only need stimulus until cycle (N-1)+(D-1); after
        // that, edges are zero but `en` remains high so propagating data can
        // settle into the far cells.
        t_max = 2*(N - 1) + (D - 1);
        cycle_count = 0;
        en = 1'b1;

        for (t = 0; t <= t_max; t++) begin
            for (i = 0; i < N; i++) begin
                if ((t - i) >= 0 && (t - i) < D)
                    q_in[i] = q_mem[i*D + (t - i)];
                else
                    q_in[i] = 16'h0000;
            end
            for (j = 0; j < N; j++) begin
                if ((t - j) >= 0 && (t - j) < D)
                    k_in[j] = k_mem[j*D + (t - j)];
                else
                    k_in[j] = 16'h0000;
            end
            @(posedge clk); #1;
            cycle_count++;
        end

        en = 1'b0;
        for (i = 0; i < N; i++) begin
            q_in[i] = 16'h0000;
            k_in[i] = 16'h0000;
        end

        @(posedge clk); #1;
        @(posedge clk); #1;

        fail_count = 0;
        pass_count = 0;

        $display("");
        $display("--- Per-cell results ---");
        for (i = 0; i < N; i++) begin
            for (j = 0; j < N; j++) begin
                hw_bits  = c_out[i][j];
                ref_bits = ref_mem[i*N + j];

                hw_r  = fp32_to_real(hw_bits);
                ref_r = fp32_to_real(ref_bits);
                err   = rabs(hw_r - ref_r);
                thresh = (REL_TOL * rabs(ref_r) > ABS_TOL)
                       ? (REL_TOL * rabs(ref_r))
                       : ABS_TOL;

                if (^hw_bits === 1'bx) begin
                    fail_count++;
                    $display("  C[%0d][%0d]: hw=%h (X bits!)  ref=%h (%g)  FAIL",
                             i, j, hw_bits, ref_bits, ref_r);
                end else if (err <= thresh) begin
                    pass_count++;
                    $display("  C[%0d][%0d]: hw=%h (%g)  ref=%h (%g)  err=%g  thresh=%g  PASS",
                             i, j, hw_bits, hw_r, ref_bits, ref_r, err, thresh);
                end else begin
                    fail_count++;
                    $display("  C[%0d][%0d]: hw=%h (%g)  ref=%h (%g)  err=%g  thresh=%g  FAIL",
                             i, j, hw_bits, hw_r, ref_bits, ref_r, err, thresh);
                end
            end
        end

        $display("");
        $display("--- Summary ---");
        $display("  PASS cells : %0d / %0d", pass_count, N*N);
        $display("  FAIL cells : %0d / %0d", fail_count, N*N);
        $display("  Streaming cycles : %0d", cycle_count);

        if (fail_count == 0)
            $display("TEST PASSED");
        else
            $display("TEST FAILED");

        $display("============================================================");
        $finish;
    end : main_test

    initial begin : watchdog
        #(CLK_PERIOD * 10000);
        $display("WATCHDOG TIMEOUT");
        $display("TEST FAILED");
        $finish;
    end : watchdog

endmodule

`default_nettype wire
