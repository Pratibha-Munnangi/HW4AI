//-----------------------------------------------------------------------------
// crossbar_tb.sv
// Testbench for crossbar_mac
//
// Loads weight matrix:
//   W = [[ 1,-1, 1,-1],
//        [ 1, 1,-1,-1],
//        [-1, 1, 1,-1],
//        [-1,-1,-1, 1]]
// Applies input vector in = [10, 20, 30, 40].
//
// Hand-calculated expected outputs:
//   out[0] =  10 + 20 - 30 - 40 = -40
//   out[1] = -10 + 20 + 30 - 40 =   0
//   out[2] =  10 - 20 + 30 - 40 = -20
//   out[3] = -10 - 20 - 30 + 40 = -20
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module crossbar_tb;

    localparam int N     = 4;
    localparam int IN_W  = 8;
    localparam int ACC_W = 16;

    logic                          clk;
    logic                          rst_n;
    logic                          load_w;
    logic [N-1:0][N-1:0]           w_bits_in;
    logic signed [IN_W-1:0]        in_vec  [N];
    logic signed [N*ACC_W-1:0]     out_vec_flat;

    // Unpack flat output for readable per-column access
    logic signed [ACC_W-1:0] out_vec [N];
    genvar gu;
    generate
        for (gu = 0; gu < N; gu++) begin : g_unpack
            assign out_vec[gu] = out_vec_flat[(gu+1)*ACC_W-1 -: ACC_W];
        end
    endgenerate

    // DUT
    crossbar_mac #(
        .N(N), .IN_W(IN_W), .ACC_W(ACC_W)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .load_w(load_w), .w_bits_in(w_bits_in),
        .in_vec(in_vec), .out_vec_flat(out_vec_flat)
    );

    // Clock: 10 ns period
    initial clk = 0;
    always #5 clk = ~clk;

    // Reference (golden) values
    logic signed [ACC_W-1:0] expected [N];

    // Convert +1/-1 integer to a single bit for the weight register
    function automatic logic w_to_bit(input int signed v);
        return (v == 1) ? 1'b1 : 1'b0;
    endfunction

    initial begin
        // Defaults
        rst_n     = 1'b0;
        load_w    = 1'b0;
        w_bits_in = '0;
        for (int i = 0; i < N; i++) in_vec[i] = '0;

        // Hold reset for a couple of cycles
        @(posedge clk);
        @(posedge clk);
        rst_n = 1'b1;

        // ---------------------------------------------------------------------
        // Load weights:
        //   W[i][j]:
        //     row 0:  +1 -1 +1 -1
        //     row 1:  +1 +1 -1 -1
        //     row 2:  -1 +1 +1 -1
        //     row 3:  -1 -1 -1 +1
        // ---------------------------------------------------------------------
        // row 0
        w_bits_in[0][0] = w_to_bit( 1);
        w_bits_in[0][1] = w_to_bit(-1);
        w_bits_in[0][2] = w_to_bit( 1);
        w_bits_in[0][3] = w_to_bit(-1);
        // row 1
        w_bits_in[1][0] = w_to_bit( 1);
        w_bits_in[1][1] = w_to_bit( 1);
        w_bits_in[1][2] = w_to_bit(-1);
        w_bits_in[1][3] = w_to_bit(-1);
        // row 2
        w_bits_in[2][0] = w_to_bit(-1);
        w_bits_in[2][1] = w_to_bit( 1);
        w_bits_in[2][2] = w_to_bit( 1);
        w_bits_in[2][3] = w_to_bit(-1);
        // row 3
        w_bits_in[3][0] = w_to_bit(-1);
        w_bits_in[3][1] = w_to_bit(-1);
        w_bits_in[3][2] = w_to_bit(-1);
        w_bits_in[3][3] = w_to_bit( 1);

        @(posedge clk);
        load_w = 1'b1;
        @(posedge clk);
        load_w = 1'b0;

        // ---------------------------------------------------------------------
        // Apply input vector
        // ---------------------------------------------------------------------
        in_vec[0] = 8'sd10;
        in_vec[1] = 8'sd20;
        in_vec[2] = 8'sd30;
        in_vec[3] = 8'sd40;

        // Hand-calculated expected values
        expected[0] = -16'sd40;
        expected[1] =  16'sd0;
        expected[2] = -16'sd20;
        expected[3] = -16'sd20;

        // Wait one cycle for input to settle, one cycle for registered output
        @(posedge clk);
        @(posedge clk);
        #1;  // small delay past clock edge for sampling

        // ---------------------------------------------------------------------
        // Check
        // ---------------------------------------------------------------------
        $display("---------------------------------------------------------");
        $display(" 4x4 Binary-Weight Crossbar MAC -- Simulation Results");
        $display("---------------------------------------------------------");
        $display(" Inputs : in = [%0d, %0d, %0d, %0d]",
                 in_vec[0], in_vec[1], in_vec[2], in_vec[3]);
        $display("---------------------------------------------------------");
        $display(" out[j]   expected   simulated   match");
        $display("---------------------------------------------------------");

        begin
            int errors = 0;
            for (int j = 0; j < N; j++) begin
                string status;
                status = (out_vec[j] === expected[j]) ? "OK" : "MISMATCH";
                if (out_vec[j] !== expected[j]) errors++;
                $display(" out[%0d]    %5d      %5d      %s",
                         j, expected[j], out_vec[j], status);
            end
            $display("---------------------------------------------------------");
            if (errors == 0) $display(" RESULT: PASS  (all %0d outputs match)", N);
            else             $display(" RESULT: FAIL  (%0d / %0d mismatches)", errors, N);
            $display("---------------------------------------------------------");
        end

        $finish;
    end

    // Optional waveform dump
    initial begin
        $dumpfile("crossbar.vcd");
        $dumpvars(0, crossbar_tb);
    end

endmodule
