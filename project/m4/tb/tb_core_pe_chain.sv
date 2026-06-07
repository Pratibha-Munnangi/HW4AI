`timescale 1ns/1ps
`default_nettype none

// Tests core_pe with d-chaining: drives N_BLOCKS d-blocks per tile,
// verifies acc_out matches the chained-reduce reference.
//
// Vector file format per line (whitespace-separated):
//   N_BLOCKS  a0_b0...a3_b3  a0_b0...a3_b3  ...  expected_acc
// where each block contributes 4 (a,b) FP16 pairs, and expected_acc is FP32.

module tb_core_pe_chain;

    localparam int MAX_VECS    = 128;
    localparam int MAX_BLOCKS  = 4;

    logic        clk = 0;
    logic        rst = 1;
    logic        clear = 0;
    logic        block_clear = 0;
    logic        block_first = 0;
    logic        block_last = 0;
    logic        en = 0;
    logic        valid_in = 0;
    logic [15:0] a_in = 0, b_in = 0;
    logic        valid_out;
    logic [15:0] a_out, b_out;
    logic [31:0] acc_out;

    always #5 clk = ~clk;

    core_pe u_dut (
        .clk         (clk),
        .rst         (rst),
        .clear       (clear),
        .block_clear (block_clear),
        .block_first (block_first),
        .block_last  (block_last),
        .en          (en),
        .valid_in    (valid_in),
        .a_in        (a_in),
        .b_in        (b_in),
        .valid_out   (valid_out),
        .a_out       (a_out),
        .b_out       (b_out),
        .acc_out     (acc_out)
    );

    int          n_blocks_vec [MAX_VECS];
    logic [15:0] vec_a [MAX_VECS][MAX_BLOCKS][4];
    logic [15:0] vec_b [MAX_VECS][MAX_BLOCKS][4];
    logic [31:0] vec_exp [MAX_VECS];
    int num_vecs;

    initial begin : load
        int fd, code, ii, bb, kk, nb;
        reg [8*4096-1:0] line;
        logic [15:0] a0,b0,a1,b1,a2,b2,a3,b3;
        logic [31:0] ee;
        string s;
        num_vecs = 0;
        fd = $fopen("pe_chain_vectors.mem", "r");
        if (fd == 0) begin $display("ERROR: cannot open pe_chain_vectors.mem"); $finish; end
        while (!$feof(fd)) begin
            code = $fgets(line, fd);
            if (code > 0) begin
                code = $sscanf(line, "%d", nb);
                if (code == 1 && nb > 0 && nb <= MAX_BLOCKS) begin
                    n_blocks_vec[num_vecs] = nb;
                    // Read the first integer (N_BLOCKS) again as a token, then 8*nb hex pairs, then expected
                    // We'll use a separate $fscanf-style approach by re-tokenizing.
                    // Simpler: re-read the line ourselves token-by-token using indices.
                    // Construct a scan format dynamically.
                    if (nb == 1) begin
                        code = $sscanf(line, "%d %h %h %h %h %h %h %h %h %h",
                            nb,a0,b0,a1,b1,a2,b2,a3,b3,ee);
                        vec_a[num_vecs][0][0]=a0; vec_b[num_vecs][0][0]=b0;
                        vec_a[num_vecs][0][1]=a1; vec_b[num_vecs][0][1]=b1;
                        vec_a[num_vecs][0][2]=a2; vec_b[num_vecs][0][2]=b2;
                        vec_a[num_vecs][0][3]=a3; vec_b[num_vecs][0][3]=b3;
                        vec_exp[num_vecs] = ee;
                    end else if (nb == 2) begin
                        logic [15:0] aa0,bb0,aa1,bb1,aa2,bb2,aa3,bb3;
                        code = $sscanf(line, "%d %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h",
                            nb,a0,b0,a1,b1,a2,b2,a3,b3,aa0,bb0,aa1,bb1,aa2,bb2,aa3,bb3,ee);
                        vec_a[num_vecs][0][0]=a0; vec_b[num_vecs][0][0]=b0;
                        vec_a[num_vecs][0][1]=a1; vec_b[num_vecs][0][1]=b1;
                        vec_a[num_vecs][0][2]=a2; vec_b[num_vecs][0][2]=b2;
                        vec_a[num_vecs][0][3]=a3; vec_b[num_vecs][0][3]=b3;
                        vec_a[num_vecs][1][0]=aa0; vec_b[num_vecs][1][0]=bb0;
                        vec_a[num_vecs][1][1]=aa1; vec_b[num_vecs][1][1]=bb1;
                        vec_a[num_vecs][1][2]=aa2; vec_b[num_vecs][1][2]=bb2;
                        vec_a[num_vecs][1][3]=aa3; vec_b[num_vecs][1][3]=bb3;
                        vec_exp[num_vecs] = ee;
                    end else if (nb == 4) begin
                        logic [15:0] a_v [4][4]; logic [15:0] b_v [4][4];
                        code = $sscanf(line,
                          "%d %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h",
                          nb,
                          a_v[0][0],b_v[0][0],a_v[0][1],b_v[0][1],a_v[0][2],b_v[0][2],a_v[0][3],b_v[0][3],
                          a_v[1][0],b_v[1][0],a_v[1][1],b_v[1][1],a_v[1][2],b_v[1][2],a_v[1][3],b_v[1][3],
                          a_v[2][0],b_v[2][0],a_v[2][1],b_v[2][1],a_v[2][2],b_v[2][2],a_v[2][3],b_v[2][3],
                          a_v[3][0],b_v[3][0],a_v[3][1],b_v[3][1],a_v[3][2],b_v[3][2],a_v[3][3],b_v[3][3],
                          ee);
                        for (bb = 0; bb < 4; bb++)
                            for (kk = 0; kk < 4; kk++) begin
                                vec_a[num_vecs][bb][kk] = a_v[bb][kk];
                                vec_b[num_vecs][bb][kk] = b_v[bb][kk];
                            end
                        vec_exp[num_vecs] = ee;
                    end
                    num_vecs++;
                end
            end
        end
        $fclose(fd);
        $display("Loaded %0d PE chain test cases.", num_vecs);
    end

    int fails, total_checked;

    initial begin : drive
        fails = 0; total_checked = 0;
        repeat (5) @(posedge clk);
        rst <= 0;
        @(posedge clk);

        wait (num_vecs > 0);

        for (int t = 0; t < num_vecs; t++) begin
            int nb;
            nb = n_blocks_vec[t];

            // Hard clear before this tile
            clear <= 1'b1;
            en    <= 1'b0;
            valid_in <= 1'b0;
            block_first <= 1'b0;
            block_last  <= 1'b0;
            @(posedge clk);
            clear <= 1'b0;
            en    <= 1'b1;

            for (int blk = 0; blk < nb; blk++) begin
                // Set per-block flags (held throughout block)
                block_first <= (blk == 0);
                block_last  <= (blk == nb-1);

                if (blk > 0) begin
                    // Soft clear between blocks
                    block_clear <= 1'b1;
                    @(posedge clk);
                    block_clear <= 1'b0;
                end

                // Drive 4 (a, b) pairs over 4 cycles
                for (int k = 0; k < 4; k++) begin
                    a_in     <= vec_a[t][blk][k];
                    b_in     <= vec_b[t][blk][k];
                    valid_in <= 1'b1;
                    @(posedge clk);
                end
                valid_in <= 1'b0;
                a_in     <= 16'h0;
                b_in     <= 16'h0;

                // Wait for tree-reduce (~14 cyc) and chain-add (~4 cyc).
                // For block 0: 14 cycles. For block N>0: 18 cycles. Use 20 for safety.
                repeat (20) @(posedge clk);
            end

            // After last block, acc_out should be valid
            if (acc_out !== vec_exp[t]) begin
                $display("  MISMATCH idx=%0d nb=%0d got=%08h exp=%08h",
                         t, nb, acc_out, vec_exp[t]);
                fails++;
            end
            total_checked++;
        end

        if (fails == 0)
            $display("PASS: %0d/%0d chained PE tests matched.", total_checked, num_vecs);
        else
            $display("FAIL: %0d/%0d mismatches (checked %0d).",
                     fails, num_vecs, total_checked);
        $finish;
    end

    initial begin
        #20_000_000;
        $display("ERROR: testbench timeout");
        $finish;
    end

endmodule

`default_nettype wire
