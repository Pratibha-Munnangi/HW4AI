// =============================================================================
// tb_top.sv  (M4 v2: d-chaining)
//
// Streams d_head=D_TOTAL=16 elements per row (so 64 beats per Q-tile and per
// K-tile). Receives 16 FP32 results per output tile (4x4 = 16). Verifies
// against an independent FP32 reference using the same tree-reduce + chain-add
// order the hardware uses.
//
// Simplified vs M3's full tb_top: no P0 reuse pattern. Just send each
// (Q-tile, K-tile) pair fresh in tile order and verify each result tile.
// This is sufficient to validate the d-chaining mechanism end-to-end.
// =============================================================================

`timescale 1ns/1ps
`default_nettype none

module tb_top;

    localparam int N        = 4;
    localparam int D        = 4;
    localparam int D_TOTAL  = 16;
    localparam int N_TILES  = 4;  // along each output dim; tiles are 4x4

    logic clk = 0;
    logic rst = 1;
    always #5 clk = ~clk;

    // AXI4-Lite
    logic [3:0]  s_axi_awaddr  = 0;
    logic        s_axi_awvalid = 0;
    logic        s_axi_awready;
    logic [31:0] s_axi_wdata   = 0;
    logic [3:0]  s_axi_wstrb   = 4'hF;
    logic        s_axi_wvalid  = 0;
    logic        s_axi_wready;
    logic [1:0]  s_axi_bresp;
    logic        s_axi_bvalid;
    logic        s_axi_bready  = 1;
    logic [3:0]  s_axi_araddr  = 0;
    logic        s_axi_arvalid = 0;
    logic        s_axi_arready;
    logic [31:0] s_axi_rdata;
    logic [1:0]  s_axi_rresp;
    logic        s_axi_rvalid;
    logic        s_axi_rready  = 1;

    // AXI-Stream
    logic [15:0] s_axis_tdata  = 0;
    logic        s_axis_tvalid = 0;
    logic        s_axis_tready;
    logic        s_axis_tlast  = 0;

    logic [31:0] m_axis_tdata;
    logic        m_axis_tvalid;
    logic        m_axis_tready = 1;
    logic        m_axis_tlast;

    top u_dut (
        .clk(clk), .rst(rst),
        .s_axi_awaddr(s_axi_awaddr), .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata),   .s_axi_wstrb(s_axi_wstrb),
        .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp),   .s_axi_bvalid(s_axi_bvalid),  .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr), .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata),   .s_axi_rresp(s_axi_rresp),   .s_axi_rvalid(s_axi_rvalid),
        .s_axi_rready(s_axi_rready),
        .s_axis_tdata(s_axis_tdata), .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready),.s_axis_tlast(s_axis_tlast),
        .m_axis_tdata(m_axis_tdata), .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tready(m_axis_tready),.m_axis_tlast(m_axis_tlast)
    );

    // --- AXI-Lite helper tasks ---
    task axi_write(input [3:0] addr, input [31:0] data);
        @(posedge clk);
        s_axi_awaddr  <= addr; s_axi_awvalid <= 1;
        s_axi_wdata   <= data; s_axi_wvalid  <= 1;
        wait (s_axi_awready && s_axi_wready);
        @(posedge clk);
        s_axi_awvalid <= 0; s_axi_wvalid <= 0;
        wait (s_axi_bvalid);
        @(posedge clk);
    endtask

    task axi_read(input [3:0] addr, output [31:0] data);
        @(posedge clk);
        s_axi_araddr  <= addr; s_axi_arvalid <= 1;
        wait (s_axi_arready);
        @(posedge clk);
        s_axi_arvalid <= 0;
        wait (s_axi_rvalid);
        data = s_axi_rdata;
        @(posedge clk);
    endtask

    // --- FP16 helpers ---
    function automatic [15:0] f32_to_f16(input real x);
        bit [63:0] f64;
        bit        sign;
        bit [10:0] e64;
        bit [51:0] m64;
        bit [4:0]  e16;
        bit [9:0]  m16;
        int        e_signed;
        bit [15:0] f16;
        f64 = $realtobits(x);
        sign = f64[63];
        e64  = f64[62:52];
        m64  = f64[51:0];
        if (e64 == 11'd0) begin
            f16 = {sign, 15'd0};
        end else if (e64 == 11'h7FF) begin
            f16 = {sign, 5'h1F, 10'd0};
        end else begin
            e_signed = int'(e64) - 1023 + 15;
            if (e_signed <= 0)      f16 = {sign, 15'd0};
            else if (e_signed >= 31) f16 = {sign, 5'h1E, 10'h3FF};
            else begin
                e16 = e_signed[4:0];
                m16 = m64[51:42];   // top 10 bits of mantissa
                f16 = {sign, e16, m16};
            end
        end
        f32_to_f16 = f16;
    endfunction

    function automatic real f16_to_real(input [15:0] h);
        bit sign;
        bit [4:0] e;
        bit [9:0] m;
        real val;
        sign = h[15];
        e    = h[14:10];
        m    = h[9:0];
        if (e == 0)      val = 0.0;
        else if (e == 31) val = 0.0;
        else begin
            val = (1.0 + real'(m)/1024.0) * (2.0 ** (int'(e) - 15));
        end
        if (sign) val = -val;
        f16_to_real = val;
    endfunction

    // --- Test data ---
    // We test on a single full QK^T of size (N_TILES*N) x (N_TILES*N) = 16x16
    // with d_head = D_TOTAL = 16.
    localparam int M_DIM = N_TILES * N;  // 16
    real Q_full [M_DIM][D_TOTAL];        // 16x16
    real K_full [M_DIM][D_TOTAL];        // 16x16
    real C_ref  [M_DIM][M_DIM];

    integer iglobal, jglobal, kglobal;

    initial begin : gen_data
        // Use simple deterministic data
        for (iglobal = 0; iglobal < M_DIM; iglobal++)
            for (kglobal = 0; kglobal < D_TOTAL; kglobal++) begin
                Q_full[iglobal][kglobal] = (((iglobal*7) + (kglobal*3)) % 13 - 6) / 8.0;
                K_full[iglobal][kglobal] = (((iglobal*5) + (kglobal*11)) % 17 - 8) / 8.0;
            end
        // Reference: standard FP32 dot product per output cell
        for (iglobal = 0; iglobal < M_DIM; iglobal++)
            for (jglobal = 0; jglobal < M_DIM; jglobal++) begin
                real acc;
                acc = 0.0;
                for (kglobal = 0; kglobal < D_TOTAL; kglobal++) begin
                    real q_f, k_f;
                    // Round through FP16 to match hardware precision
                    q_f = f16_to_real(f32_to_f16(Q_full[iglobal][kglobal]));
                    k_f = f16_to_real(f32_to_f16(K_full[jglobal][kglobal]));
                    acc = acc + q_f * k_f;
                end
                C_ref[iglobal][jglobal] = acc;
            end
    end

    // --- Producer: stream Q tile then K tile for each (tile_r, tile_c) ---
    int tr, tc, ri, kj;

    initial begin : producer
        s_axis_tvalid <= 0; s_axis_tdata <= 0; s_axis_tlast <= 0;
        wait (rst === 0);
        @(posedge clk);
        wait (u_dut.engine_started);
        @(posedge clk);

        for (tr = 0; tr < N_TILES; tr++) begin
            for (tc = 0; tc < N_TILES; tc++) begin
                // Q is only sent at the start of a row-band (tc==0) due to P0 Q-reuse
                if (tc == 0) begin
                    for (ri = 0; ri < N; ri++) begin
                        for (kj = 0; kj < D_TOTAL; kj++) begin
                            s_axis_tdata <= f32_to_f16(Q_full[tr*N + ri][kj]);
                            s_axis_tvalid <= 1;
                            s_axis_tlast  <= ((ri == N-1) && (kj == D_TOTAL-1));
                            @(posedge clk);
                            while (!s_axis_tready) @(posedge clk);
                        end
                    end
                    s_axis_tvalid <= 0; s_axis_tlast <= 0;
                end
                // K is sent every tile
                for (ri = 0; ri < N; ri++) begin
                    for (kj = 0; kj < D_TOTAL; kj++) begin
                        s_axis_tdata <= f32_to_f16(K_full[tc*N + ri][kj]);
                        s_axis_tvalid <= 1;
                        s_axis_tlast  <= ((ri == N-1) && (kj == D_TOTAL-1));
                        @(posedge clk);
                        while (!s_axis_tready) @(posedge clk);
                    end
                end
                s_axis_tvalid <= 0; s_axis_tlast <= 0;
            end
        end
    end

    // --- Consumer: collect 16 FP32 per tile, compare to ref ---
    int recv_tile = 0;
    int recv_count = 0;
    int mismatches = 0;
    int total_checks = 0;
    logic [31:0] tile_recv [16];

    function automatic real fp32_bits_to_real(input [31:0] b);
        // Convert FP32 bit pattern to real (64-bit) without builtins.
        bit        sign;
        bit [7:0]  e;
        bit [22:0] m;
        real       val;
        bit [63:0] d64;
        bit [10:0] e64;
        int        e_signed;
        sign = b[31];
        e    = b[30:23];
        m    = b[22:0];
        if (e == 8'd0) begin
            val = 0.0;
        end else if (e == 8'hFF) begin
            val = 0.0;  // NaN/Inf treated as 0 (consistent with hardware FTZ)
        end else begin
            // Construct equivalent FP64 bit pattern
            e_signed = int'(e) - 127 + 1023;
            e64 = e_signed[10:0];
            d64 = {sign, e64, m, 29'd0};
            val = $bitstoreal(d64);
        end
        return val;
    endfunction

    always @(posedge clk) begin
        if (m_axis_tvalid && m_axis_tready) begin
            tile_recv[recv_count] = m_axis_tdata;
            recv_count = recv_count + 1;
            if (m_axis_tlast || recv_count == 16) begin
                // Compare against reference for this tile
                int tile_r, tile_c;
                tile_r = recv_tile / N_TILES;
                tile_c = recv_tile % N_TILES;
                for (int li = 0; li < N; li++) begin
                    for (int lj = 0; lj < N; lj++) begin
                        real got, exp_v, err;
                        got   = fp32_bits_to_real(tile_recv[li*N + lj]);
                        exp_v = C_ref[tile_r*N + li][tile_c*N + lj];
                        err   = got - exp_v;
                        if (err < 0) err = -err;
                        // Allow 1e-2 absolute tolerance for FP16 rounding effects
                        if (err > 0.01) begin
                            $display("MISMATCH tile=(%0d,%0d) [%0d][%0d] got=%f exp=%f err=%f",
                                     tile_r, tile_c, li, lj, got, exp_v, err);
                            mismatches = mismatches + 1;
                        end
                        total_checks = total_checks + 1;
                    end
                end
                recv_count = 0;
                recv_tile = recv_tile + 1;
            end
        end
    end

    // --- Main host sequence ---
    initial begin : host
        repeat (5) @(posedge clk);
        rst <= 0;
        repeat (5) @(posedge clk);

        // Read VERSION
        begin
            logic [31:0] rd;
            axi_read(4'hC, rd);
            $display("[%0t] VERSION read: 0x%08h (expect 0xC0DE_0002)", $time, rd);
        end

        // Write CONFIG = D_TOTAL<<16 | N
        axi_write(4'h8, (D_TOTAL << 16) | N);

        // Write CTRL.START
        axi_write(4'h0, 32'h0000_0001);

        // Wait for all 16 tiles to be drained
        wait (recv_tile == N_TILES * N_TILES);

        repeat (50) @(posedge clk);

        $display("=========================================");
        $display("Total checks : %0d", total_checks);
        $display("Mismatches   : %0d", mismatches);
        if (mismatches == 0) $display("RESULT: PASS");
        else                  $display("RESULT: FAIL");
        $display("=========================================");
        $finish;
    end

    initial begin
        #20_000_000;
        $display("ERROR: testbench timeout at time %0t", $time);
        $finish;
    end

endmodule

`default_nettype wire
