// =============================================================================
// File   : interface.sv
// Module : qkt_interface
//
// Note: SystemVerilog reserves the keyword `interface` for the SV interface
// construct, so the module is named `qkt_interface`. The file is named
// `interface.sv` to match the M2 rubric's path requirement
// (project/m2/rtl/interface.sv).
//
// Purpose: AXI4-Lite control/status + AXI4-Stream data interface for the QK^T
//          chiplet. Top module of the M2 interface deliverable.
//
// AXI4-Lite slave (32-bit address, 32-bit data):
//   0x00  CTRL    : [0] = START (W1S, self-clear), [1] = ABORT (W1S, self-clear)
//   0x04  STATUS  : [0] = BUSY (RO), [1] = DONE (RW1C), [2] = ERR (RW1C)
//   0x08  CONFIG  : [15:0]  = N (matrix dim), [31:16] = D (inner dim)
//   0x0C  VERSION : 32'hC0DE_0001 (read-only constant)
//
// AXI4-Stream:
//   s_axis  : 16-bit FP16 input  (Q/K elements). TLAST marks end-of-tile.
//   m_axis  : 32-bit FP32 output (C elements). FP16 zero-extended for M2.
//
// For M2 the AXI-Lite block drives a placeholder "BUSY for FIXED_BUSY_CYCLES,
// then DONE" engine so the protocol is exercised end-to-end. M3 replaces the
// placeholder with the real compute_core hookup, and the Stream channel with
// the diagonal-skew adapter feeding q_in_bus / k_in_bus and draining
// c_out_bus.
//
// Reset    : synchronous, active-high
// Clock    : single domain (clk; broadcast to AXI-Stream too)
// =============================================================================

`default_nettype none

module qkt_interface #(
    parameter int FIXED_BUSY_CYCLES = 16
) (
    input  logic        clk,
    input  logic        rst,

    // AXI4-Lite slave
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

    // AXI-Stream slave (Q/K input)
    input  logic [15:0] s_axis_tdata,
    input  logic        s_axis_tvalid,
    output logic        s_axis_tready,
    input  logic        s_axis_tlast,

    // AXI-Stream master (C output)
    output logic [31:0] m_axis_tdata,
    output logic        m_axis_tvalid,
    input  logic        m_axis_tready,
    output logic        m_axis_tlast
);

    localparam logic [3:0] ADDR_CTRL    = 4'h0;
    localparam logic [3:0] ADDR_STATUS  = 4'h4;
    localparam logic [3:0] ADDR_CONFIG  = 4'h8;
    localparam logic [3:0] ADDR_VERSION = 4'hC;
    localparam logic [31:0] VERSION_CONST = 32'hC0DE_0001;

    logic        ctrl_start_pulse;
    logic        ctrl_abort_pulse;
    logic [15:0] cfg_N;
    logic [15:0] cfg_D;
    logic        sts_busy;
    logic        sts_done;
    logic        sts_err;

    // ---- Write FSM ----
    typedef enum logic [1:0] { WR_IDLE = 2'd0, WR_RESP = 2'd1 } wr_state_e;
    wr_state_e wr_state;
    logic [3:0]  wr_addr_q;
    logic [31:0] wr_data_q;

    logic wr_handshake_now;
    assign wr_handshake_now = (wr_state == WR_IDLE) && s_axi_awvalid && s_axi_wvalid;

    assign s_axi_awready = (wr_state == WR_IDLE);
    assign s_axi_wready  = (wr_state == WR_IDLE);

    // ---- Read FSM ----
    typedef enum logic [1:0] { RD_IDLE = 2'd0, RD_RESP = 2'd1 } rd_state_e;
    rd_state_e   rd_state;
    logic [3:0]  rd_addr_q;
    assign s_axi_arready = (rd_state == RD_IDLE);

    logic [31:0] rd_mux;
    logic        rd_addr_ok;
    always_comb begin
        case (rd_addr_q)
            ADDR_CTRL:    rd_mux = 32'h0000_0000;
            ADDR_STATUS:  rd_mux = {29'd0, sts_err, sts_done, sts_busy};
            ADDR_CONFIG:  rd_mux = {cfg_D, cfg_N};
            ADDR_VERSION: rd_mux = VERSION_CONST;
            default:      rd_mux = 32'hDEAD_BEEF;
        endcase
    end
    assign rd_addr_ok = (rd_addr_q == ADDR_CTRL)   ||
                        (rd_addr_q == ADDR_STATUS) ||
                        (rd_addr_q == ADDR_CONFIG) ||
                        (rd_addr_q == ADDR_VERSION);

    logic wr_addr_ok;
    assign wr_addr_ok = (wr_addr_q == ADDR_CTRL)   ||
                        (wr_addr_q == ADDR_CONFIG) ||
                        (wr_addr_q == ADDR_STATUS);

    always_ff @(posedge clk) begin : wr_fsm
        if (rst) begin
            wr_state         <= WR_IDLE;
            wr_addr_q        <= 4'h0;
            wr_data_q        <= 32'd0;
            s_axi_bvalid     <= 1'b0;
            s_axi_bresp      <= 2'b00;
            ctrl_start_pulse <= 1'b0;
            ctrl_abort_pulse <= 1'b0;
            cfg_N            <= 16'd4;
            cfg_D            <= 16'd4;
        end else begin
            ctrl_start_pulse <= 1'b0;
            ctrl_abort_pulse <= 1'b0;

            case (wr_state)
                WR_IDLE: begin
                    if (wr_handshake_now) begin
                        wr_addr_q <= s_axi_awaddr;
                        wr_data_q <= s_axi_wdata;
                        wr_state  <= WR_RESP;
                    end
                end
                WR_RESP: begin
                    case (wr_addr_q)
                        ADDR_CTRL: begin
                            if (wr_data_q[0]) ctrl_start_pulse <= 1'b1;
                            if (wr_data_q[1]) ctrl_abort_pulse <= 1'b1;
                        end
                        ADDR_CONFIG: begin
                            cfg_N <= wr_data_q[15:0];
                            cfg_D <= wr_data_q[31:16];
                        end
                        default: ;
                    endcase
                    s_axi_bresp  <= wr_addr_ok ? 2'b00 : 2'b10;
                    s_axi_bvalid <= 1'b1;

                    if (s_axi_bvalid && s_axi_bready) begin
                        s_axi_bvalid <= 1'b0;
                        wr_state     <= WR_IDLE;
                    end
                end
                default: wr_state <= WR_IDLE;
            endcase
        end
    end

    always_ff @(posedge clk) begin : rd_fsm
        if (rst) begin
            rd_state     <= RD_IDLE;
            rd_addr_q    <= 4'h0;
            s_axi_rvalid <= 1'b0;
            s_axi_rresp  <= 2'b00;
            s_axi_rdata  <= 32'd0;
        end else begin
            case (rd_state)
                RD_IDLE: begin
                    if (s_axi_arvalid && s_axi_arready) begin
                        rd_addr_q <= s_axi_araddr;
                        rd_state  <= RD_RESP;
                    end
                end
                RD_RESP: begin
                    s_axi_rdata  <= rd_mux;
                    s_axi_rresp  <= rd_addr_ok ? 2'b00 : 2'b10;
                    s_axi_rvalid <= 1'b1;
                    if (s_axi_rvalid && s_axi_rready) begin
                        s_axi_rvalid <= 1'b0;
                        rd_state     <= RD_IDLE;
                    end
                end
                default: rd_state <= RD_IDLE;
            endcase
        end
    end

    // ---- Placeholder engine (M2) ----
    logic [7:0] busy_ctr;
    logic do_w1c_status;
    assign do_w1c_status = (wr_state == WR_RESP) &&
                           (wr_addr_q == ADDR_STATUS) &&
                            s_axi_bvalid && s_axi_bready;

    always_ff @(posedge clk) begin : engine_seq
        if (rst) begin
            sts_busy <= 1'b0;
            sts_done <= 1'b0;
            sts_err  <= 1'b0;
            busy_ctr <= 8'd0;
        end else begin
            if (ctrl_abort_pulse) begin
                sts_busy <= 1'b0;
                busy_ctr <= 8'd0;
            end
            if (ctrl_start_pulse) begin
                if (sts_busy) begin
                    sts_err <= 1'b1;
                end else begin
                    sts_busy <= 1'b1;
                    busy_ctr <= 8'(FIXED_BUSY_CYCLES);
                end
            end
            if (sts_busy && !ctrl_abort_pulse) begin
                if (busy_ctr == 8'd1) begin
                    sts_busy <= 1'b0;
                    sts_done <= 1'b1;
                end
                busy_ctr <= busy_ctr - 8'd1;
            end
            if (do_w1c_status) begin
                if (wr_data_q[1]) sts_done <= 1'b0;
                if (wr_data_q[2]) sts_err  <= 1'b0;
            end
        end
    end

    // ---- AXI-Stream skid ----
    logic        skid_valid;
    logic [31:0] skid_data;
    logic        skid_last;

    assign s_axis_tready = !skid_valid || m_axis_tready;
    assign m_axis_tvalid = skid_valid;
    assign m_axis_tdata  = skid_data;
    assign m_axis_tlast  = skid_last;

    always_ff @(posedge clk) begin : stream_seq
        if (rst) begin
            skid_valid <= 1'b0;
            skid_data  <= 32'd0;
            skid_last  <= 1'b0;
        end else begin
            if (skid_valid && m_axis_tready)
                skid_valid <= 1'b0;
            if (s_axis_tvalid && s_axis_tready) begin
                skid_data  <= {16'h0000, s_axis_tdata};
                skid_last  <= s_axis_tlast;
                skid_valid <= 1'b1;
            end
        end
    end

endmodule

`default_nettype wire
