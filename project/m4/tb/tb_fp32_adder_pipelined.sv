`timescale 1ns/1ps
`default_nettype none

module tb_fp32_adder_pipelined;

    localparam int MAX_VECS = 1024;
    localparam int LATENCY  = 3;

    logic        clk = 0;
    logic        rst = 1;
    logic        valid_in;
    logic [31:0] a, b;
    logic        valid_out;
    logic [31:0] sum;

    always #5 clk = ~clk;

    fp32_adder_pipelined u_dut (
        .clk      (clk),
        .rst      (rst),
        .valid_in (valid_in),
        .a        (a),
        .b        (b),
        .valid_out(valid_out),
        .sum      (sum)
    );

    logic [31:0] vec_a   [MAX_VECS];
    logic [31:0] vec_b   [MAX_VECS];
    logic [31:0] vec_exp [MAX_VECS];
    int num_vecs;

    initial begin : load
        int fd, code;
        reg [8*256-1:0] line;
        logic [31:0] aa, bb, ee;
        num_vecs = 0;
        fd = $fopen("fp32_add_vectors.mem", "r");
        if (fd == 0) begin
            $display("ERROR: cannot open fp32_add_vectors.mem");
            $finish;
        end
        while (!$feof(fd)) begin
            code = $fgets(line, fd);
            if (code > 0) begin
                if ($sscanf(line, "%h %h %h", aa, bb, ee) == 3) begin
                    vec_a  [num_vecs] = aa;
                    vec_b  [num_vecs] = bb;
                    vec_exp[num_vecs] = ee;
                    num_vecs++;
                end
            end
        end
        $fclose(fd);
        $display("Loaded %0d vectors.", num_vecs);
    end

    int sent_idx;
    int recv_idx;
    int fails;
    int total_checked;

    initial begin : drive
        valid_in = 0;
        a = 0; b = 0;
        sent_idx = 0;
        recv_idx = 0;
        fails = 0;
        total_checked = 0;

        repeat (5) @(posedge clk);
        rst <= 0;
        @(posedge clk);

        while (sent_idx < num_vecs) begin
            valid_in <= 1'b1;
            a        <= vec_a[sent_idx];
            b        <= vec_b[sent_idx];
            sent_idx <= sent_idx + 1;
            @(posedge clk);
        end
        valid_in <= 1'b0;
        a        <= 32'd0;
        b        <= 32'd0;

        repeat (LATENCY + 5) @(posedge clk);

        if (fails == 0)
            $display("PASS: %0d/%0d vectors matched.", total_checked, num_vecs);
        else
            $display("FAIL: %0d/%0d vectors mismatched (checked %0d).",
                     fails, num_vecs, total_checked);
        $finish;
    end

    always @(posedge clk) begin
        if (!rst && valid_out) begin
            if (recv_idx < num_vecs) begin
                if (sum !== vec_exp[recv_idx]) begin
                    $display("  MISMATCH idx=%0d: a=%08h b=%08h got=%08h exp=%08h",
                             recv_idx, vec_a[recv_idx], vec_b[recv_idx], sum, vec_exp[recv_idx]);
                    fails++;
                end
                total_checked++;
                recv_idx++;
            end
        end
    end

    initial begin
        #1_000_000;
        $display("ERROR: testbench timeout");
        $finish;
    end

endmodule

`default_nettype wire
