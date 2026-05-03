`timescale 1ns/1ps
`default_nettype none

module tb_interface;

    localparam int CLK_PERIOD = 10;

    logic clk, rst;
    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // AXI-Lite signals
    logic [3:0]  awaddr;
    logic        awvalid, awready;
    logic [31:0] wdata;
    logic [3:0]  wstrb;
    logic        wvalid, wready;
    logic [1:0]  bresp;
    logic        bvalid, bready;
    logic [3:0]  araddr;
    logic        arvalid, arready;
    logic [31:0] rdata;
    logic [1:0]  rresp;
    logic        rvalid, rready;

    // AXI-Stream signals
    logic [15:0] s_axis_tdata;
    logic        s_axis_tvalid, s_axis_tready, s_axis_tlast;
    logic [31:0] m_axis_tdata;
    logic        m_axis_tvalid, m_axis_tready, m_axis_tlast;

    qkt_interface dut (
        .clk            (clk),
        .rst            (rst),
        .s_axi_awaddr   (awaddr),
        .s_axi_awvalid  (awvalid),
        .s_axi_awready  (awready),
        .s_axi_wdata    (wdata),
        .s_axi_wstrb    (wstrb),
        .s_axi_wvalid   (wvalid),
        .s_axi_wready   (wready),
        .s_axi_bresp    (bresp),
        .s_axi_bvalid   (bvalid),
        .s_axi_bready   (bready),
        .s_axi_araddr   (araddr),
        .s_axi_arvalid  (arvalid),
        .s_axi_arready  (arready),
        .s_axi_rdata    (rdata),
        .s_axi_rresp    (rresp),
        .s_axi_rvalid   (rvalid),
        .s_axi_rready   (rready),
        .s_axis_tdata   (s_axis_tdata),
        .s_axis_tvalid  (s_axis_tvalid),
        .s_axis_tready  (s_axis_tready),
        .s_axis_tlast   (s_axis_tlast),
        .m_axis_tdata   (m_axis_tdata),
        .m_axis_tvalid  (m_axis_tvalid),
        .m_axis_tready  (m_axis_tready),
        .m_axis_tlast   (m_axis_tlast)
    );

    integer fail_count, pass_count;

    task automatic check(input string name,
                         input logic [31:0] got,
                         input logic [31:0] expected);
        begin
            if (got === expected) begin
                pass_count = pass_count + 1;
                $display("  [PASS] %s : got=%h expected=%h", name, got, expected);
            end else begin
                fail_count = fail_count + 1;
                $display("  [FAIL] %s : got=%h expected=%h", name, got, expected);
            end
        end
    endtask

    task automatic axil_write(input logic [3:0] addr, input logic [31:0] data);
        begin
            @(posedge clk); #1;
            awaddr  = addr;
            awvalid = 1'b1;
            wdata   = data;
            wstrb   = 4'hF;
            wvalid  = 1'b1;
            do @(posedge clk); while (!(awready && wready));
            #1;
            awvalid = 1'b0;
            wvalid  = 1'b0;
            bready = 1'b1;
            do @(posedge clk); while (!bvalid);
            #1;
            bready = 1'b0;
            $display("  [LITE_W] addr=%h data=%h bresp=%b", addr, data, bresp);
        end
    endtask

    task automatic axil_read(input logic [3:0] addr, output logic [31:0] data);
        begin
            @(posedge clk); #1;
            araddr  = addr;
            arvalid = 1'b1;
            do @(posedge clk); while (!arready);
            #1;
            arvalid = 1'b0;
            rready  = 1'b1;
            do @(posedge clk); while (!rvalid);
            data = rdata;
            #1;
            rready = 1'b0;
            $display("  [LITE_R] addr=%h data=%h rresp=%b", addr, data, rresp);
        end
    endtask

    initial begin : main
        logic [31:0] got;

        $dumpfile("sim/tb_interface.vcd");
        $dumpvars(0, tb_interface);

        $display("============================================================");
        $display(" tb_interface : AXI4-Lite + AXI4-Stream protocol checks");
        $display("============================================================");

        awaddr = 0; awvalid = 0; wdata = 0; wstrb = 0; wvalid = 0; bready = 0;
        araddr = 0; arvalid = 0; rready = 0;
        s_axis_tdata  = 16'h0000;
        s_axis_tvalid = 1'b0;
        s_axis_tlast  = 1'b0;
        m_axis_tready = 1'b0;

        fail_count = 0;
        pass_count = 0;

        rst = 1'b1;
        repeat (3) @(posedge clk);
        #1; rst = 1'b0;
        @(posedge clk); #1;

        // ---- Sub-test 1: write CONFIG, read back
        $display("");
        $display("--- Sub-test 1: AXI-Lite write + read CONFIG ---");
        axil_write(4'h8, 32'h0040_0010);   // D=0x40, N=0x10
        axil_read (4'h8, got);
        check("CONFIG readback", got, 32'h0040_0010);

        // ---- Sub-test 2: read VERSION
        $display("");
        $display("--- Sub-test 2: AXI-Lite read VERSION ---");
        axil_read(4'hC, got);
        check("VERSION readback", got, 32'hC0DE_0001);

        // ---- Sub-test 3: AXI-Stream beat passthrough
        $display("");
        $display("--- Sub-test 3: AXI-Stream beat passthrough ---");
        m_axis_tready = 1'b1;

        @(posedge clk); #1;
        s_axis_tdata  = 16'hCAFE;
        s_axis_tlast  = 1'b1;
        s_axis_tvalid = 1'b1;
        do @(posedge clk); while (!s_axis_tready);
        #1;
        s_axis_tvalid = 1'b0;
        s_axis_tlast  = 1'b0;

        do @(posedge clk); while (!m_axis_tvalid);
        check("Stream tdata out", m_axis_tdata, 32'h0000_CAFE);
        check("Stream tlast out", {31'd0, m_axis_tlast}, 32'h0000_0001);
        #1;
        m_axis_tready = 1'b0;

        $display("");
        $display("--- Summary ---");
        $display("  PASS : %0d", pass_count);
        $display("  FAIL : %0d", fail_count);
        if (fail_count == 0)
            $display("TEST PASSED");
        else
            $display("TEST FAILED");

        $display("============================================================");
        $finish;
    end : main

    initial begin : watchdog
        #(CLK_PERIOD * 2000);
        $display("WATCHDOG TIMEOUT");
        $display("TEST FAILED");
        $finish;
    end : watchdog

endmodule

`default_nettype wire
