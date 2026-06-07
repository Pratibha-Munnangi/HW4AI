// =============================================================================
// File   : interface.sv
// Module : qkt_interface
//
// CSR-decoupled AXI4-Lite + AXI4-Stream interface for the QK^T accelerator.
// CSR map:
//   0x00 CTRL    [0]=START (W1S pulse), [1]=ABORT (W1S pulse)
//   0x04 STATUS  [0]=BUSY (RO), [1]=DONE (W1C), [2]=ERR (W1C)
//   0x08 CONFIG  [15:0]=N, [31:16]=D
//   0x0C VERSION read-only 0xC0DE_0002
// =============================================================================

`default_nettype none

module qkt_interface (
    input  logic        clk,
    input  logic        rst,

    input  logic [3:0]  s_axi_awaddr,
    input  logic        s_axi_awvalid,
    output logic        s_axi_awready,
    input  logic [31:0] s_axi_wdata,
    input  logic [3:0]  s_axi_wstrb,
    input  logic        s_axi_wvalid,
    output logic        s_axi_wready,
    output logic [1:0]  s_axi_bresp,
    output logic        s_axi_bvalid,
    input  logic        s_axi_bready,
    input  logic [3:0]  s_axi_araddr,
    input  logic        s_axi_arvalid,
    output logic        s_axi_arready,
    output logic [31:0] s_axi_rdata,
    output logic [1:0]  s_axi_rresp,
    output logic        s_axi_rvalid,
    input  logic        s_axi_rready,

    input  logic [15:0] s_axis_tdata,
    input  logic        s_axis_tvalid,
    output logic        s_axis_tready,
    input  logic        s_axis_tlast,

    output logic [31:0] m_axis_tdata,
    output logic        m_axis_tvalid,
    input  logic        m_axis_tready,
    output logic        m_axis_tlast,

    output logic        start_pulse,
    output logic        abort_pulse,
    output logic [15:0] cfg_N,
    output logic [15:0] cfg_D,
    input  logic        engine_busy,
    input  logic        engine_done,
    input  logic        engine_err,

    output logic [15:0] eng_axis_tdata,
    output logic        eng_axis_tvalid,
    input  logic        eng_axis_tready,
    output logic        eng_axis_tlast,

    input  logic [31:0] c_axis_tdata,
    input  logic        c_axis_tvalid,
    output logic        c_axis_tready,
    input  logic        c_axis_tlast
);

    localparam logic [31:0] VERSION_VAL = 32'hC0DE_0002;

    logic [15:0] reg_N, reg_D;
    logic        status_done_sticky;
    logic        status_err_sticky;

    assign cfg_N = reg_N;
    assign cfg_D = reg_D;

    // --- Write channel ---
    logic aw_hs, w_hs;
    assign aw_hs = s_axi_awvalid && s_axi_awready;
    assign w_hs  = s_axi_wvalid  && s_axi_wready;
    assign s_axi_awready = !s_axi_bvalid;
    assign s_axi_wready  = !s_axi_bvalid;

    logic [3:0] awaddr_q;
    logic       aw_captured;

    always_ff @(posedge clk) begin
        if (rst) begin
            awaddr_q     <= 4'd0;
            aw_captured  <= 1'b0;
            reg_N        <= 16'd4;
            reg_D        <= 16'd4;
            start_pulse  <= 1'b0;
            abort_pulse  <= 1'b0;
            s_axi_bvalid <= 1'b0;
            s_axi_bresp  <= 2'b00;
            status_done_sticky <= 1'b0;
            status_err_sticky  <= 1'b0;
        end else begin
            start_pulse <= 1'b0;
            abort_pulse <= 1'b0;

            if (engine_done) status_done_sticky <= 1'b1;
            if (engine_err ) status_err_sticky  <= 1'b1;

            if (aw_hs) begin
                awaddr_q    <= s_axi_awaddr;
                aw_captured <= 1'b1;
            end

            if ((aw_hs || aw_captured) && w_hs) begin
                logic [3:0] addr;
                addr = aw_hs ? s_axi_awaddr : awaddr_q;
                case (addr)
                    4'h0: begin
                        if (s_axi_wdata[0]) start_pulse <= 1'b1;
                        if (s_axi_wdata[1]) abort_pulse <= 1'b1;
                    end
                    4'h4: begin
                        if (s_axi_wdata[1]) status_done_sticky <= 1'b0;
                        if (s_axi_wdata[2]) status_err_sticky  <= 1'b0;
                    end
                    4'h8: begin
                        reg_N <= s_axi_wdata[15:0];
                        reg_D <= s_axi_wdata[31:16];
                    end
                    default: ;
                endcase
                s_axi_bvalid <= 1'b1;
                s_axi_bresp  <= 2'b00;
                aw_captured  <= 1'b0;
            end

            if (s_axi_bvalid && s_axi_bready)
                s_axi_bvalid <= 1'b0;
        end
    end

    // --- Read channel ---
    assign s_axi_arready = !s_axi_rvalid;

    always_ff @(posedge clk) begin
        if (rst) begin
            s_axi_rvalid <= 1'b0;
            s_axi_rdata  <= 32'd0;
            s_axi_rresp  <= 2'b00;
        end else begin
            if (s_axi_arvalid && s_axi_arready) begin
                s_axi_rvalid <= 1'b1;
                s_axi_rresp  <= 2'b00;
                case (s_axi_araddr)
                    4'h0: s_axi_rdata <= 32'd0;
                    4'h4: s_axi_rdata <= {29'd0, status_err_sticky,
                                          status_done_sticky, engine_busy};
                    4'h8: s_axi_rdata <= {reg_D, reg_N};
                    4'hC: s_axi_rdata <= VERSION_VAL;
                    default: s_axi_rdata <= 32'hDEAD_BEEF;
                endcase
            end
            if (s_axi_rvalid && s_axi_rready)
                s_axi_rvalid <= 1'b0;
        end
    end

    // --- Stream passthrough ---
    assign eng_axis_tdata  = s_axis_tdata;
    assign eng_axis_tvalid = s_axis_tvalid;
    assign eng_axis_tlast  = s_axis_tlast;
    assign s_axis_tready   = eng_axis_tready;

    assign m_axis_tdata    = c_axis_tdata;
    assign m_axis_tvalid   = c_axis_tvalid;
    assign m_axis_tlast    = c_axis_tlast;
    assign c_axis_tready   = m_axis_tready;

endmodule

`default_nettype wire
