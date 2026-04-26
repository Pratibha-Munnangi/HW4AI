// =============================================================================
// File        : mac_tb.v
// Purpose     : cf04 testbench for the `mac` module (mac_llm_A.v).
//
// Stimulus (per assignment):
//   1. Apply a=3,  b=4   for 3 cycles
//   2. Assert rst        for 1 cycle
//   3. Apply a=-5, b=2   for 2 cycles
//
// Logging     : After each posedge, $display the inputs that were just
//               sampled and the resulting accumulator value.
// Notes       : Testbench-only file. $display / # delays are used here for
//               stimulus and logging; these are NOT part of the DUT.
// =============================================================================

`timescale 1ns/1ps

module mac_tb;

    // DUT I/O
    logic               clk;
    logic               rst;
    logic signed [7:0]  a;
    logic signed [7:0]  b;
    logic signed [31:0] out;

    // Instantiate DUT
    mac dut (
        .clk (clk),
        .rst (rst),
        .a   (a),
        .b   (b),
        .out (out)
    );

    // 10ns clock (100 MHz)
    initial clk = 1'b0;
    always  #5 clk = ~clk;

    // Drive inputs before the next posedge, then log after it.
    int cycle;
    task automatic step(input logic rst_in,
                        input logic signed [7:0] a_in,
                        input logic signed [7:0] b_in);
        begin
            rst = rst_in;
            a   = a_in;
            b   = b_in;
            @(posedge clk);
            #1; // settle so 'out' reflects this edge's update
            cycle = cycle + 1;
            $display("cycle=%0d  rst=%0b  a=%0d  b=%0d  product=%0d  out=%0d",
                     cycle, rst, a, b, a*b, out);
        end
    endtask

    initial begin
        // ---- Initialize and pre-clear accumulator ----
        rst = 1'b0; a = 8'sd0; b = 8'sd0; cycle = 0;
        // One reset cycle so we start from out=0 (not shown in main log)
        rst = 1'b1;
        @(posedge clk); #1;
        rst = 1'b0;

        $display("---- Phase 1: a=3, b=4 for 3 cycles ----");
        step(1'b0, 8'sd3, 8'sd4);
        step(1'b0, 8'sd3, 8'sd4);
        step(1'b0, 8'sd3, 8'sd4);

        $display("---- Phase 2: assert rst for 1 cycle ----");
        step(1'b1, 8'sd3, 8'sd4);  // inputs are don't-care during reset

        $display("---- Phase 3: a=-5, b=2 for 2 cycles ----");
        step(1'b0, -8'sd5, 8'sd2);
        step(1'b0, -8'sd5, 8'sd2);

        $display("---- Done ----");
        $finish;
    end

endmodule
