// =============================================================================
// File   : top.sv
// Module : top
//
// QK^T accelerator top, M4 P0+P1 version.
//
//   M3 baseline   : single FSM, serial LOAD_Q -> LOAD_K -> CLEAR -> COMPUTE -> DRAIN.
//   M4 P0         : Q-row reuse across tile-column sweeps (tile_c walks 0..3
//                   inside a fixed tile_r row-band; Q only reloaded at tc==0).
//   M4 P1 (THIS)  : double-buffered Q/K + split FSM. While compute runs on
//                   bank A (current tile), load runs on bank B (next tile).
//                   At the swap point the bank pointers exchange.
//
// External ports
// --------------
// (unchanged from M3; host-side AXI4-Lite + AXI-Stream contract is identical;
//  the engine just happens to overlap I/O with compute internally.)
//
//   clk, rst            : clock + sync active-high reset
//   s_axi_*             : AXI4-Lite slave for CSR
//   s_axis_t{data,valid,ready,last} : 16-bit Q/K input stream
//   m_axis_t{data,valid,ready,last} : 32-bit C output stream
//
// Glue logic (named per M3 rubric requirement)
// --------------------------------------------
//   tile_sequencer  : two cooperating FSMs (load_fsm + compute_fsm) that
//                     ping-pong between Q/K banks 0 and 1 via a handshake.
//                     load_fsm fills the "load_bank" with the next tile's
//                     Q (if needed) and K data; compute_fsm runs CLEAR /
//                     COMPUTE / DRAIN on the "compute_bank". They swap
//                     banks at a barrier (both done with their current
//                     tile) and proceed in lockstep on the next tile.
//   diagonal_driver : combinational; reads from q_buf[compute_bank][...]
//                     and k_buf[compute_bank][...] and produces the
//                     diagonal-skew operand buses for compute_core.
//
// Double-buffering correctness invariants
// ---------------------------------------
//   1. compute_bank != load_bank at all times (one bit XOR'd on swap).
//   2. Diagonal driver reads ONLY from compute_bank; load FSM writes ONLY
//      to load_bank. They never alias.
//   3. Swap occurs only when load_done && compute_done. Either FSM may
//      reach its "done" state ahead of the other and waits.
//
// Q-row reuse (P0)
// ----------------
//   The load FSM skips its S_LOAD_Q substate when the upcoming tile_c > 0,
//   because the Q data in load_bank from the previous tile in this row-band
//   is still valid (we never overwrote it; only K changes). When tile_c
//   advances within a row-band, only K is fetched into load_bank. Q is
//   reloaded at tile_c == 0 (start of each row-band).
//
//   IMPORTANT P0 + P1 INTERACTION: because of double-buffering, the
//   "previous tile's Q in load_bank" is actually the Q of the tile we just
//   FINISHED LOADING (which was 2 tiles ago in compute-time, since compute
//   trails load by one tile in steady state). To make P0 work cleanly with
//   P1, we copy Q from the OTHER bank when reuse is needed. See the
//   load FSM's L_LOAD_Q_OR_COPY state.
//
// =============================================================================

`default_nettype none

module top (
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

    // ============================================================
    // Parameters
    // ============================================================
    localparam int N                  = 4;
    localparam int D                  = 4;
    localparam int ARRAY_LAT          = 2*(N-1) + (D-1) + 1;       // 10
    localparam int FEED_CYCLES        = (D-1) + (N-1) + 1;         // 7
    localparam int COMPUTE_TOTAL      = FEED_CYCLES + ARRAY_LAT;   // 17
    localparam int BEATS_PER_LOAD     = N*D;                       // 16
    localparam int NUM_TILES_PER_DIM  = 4;                         // 16 / N

    // ============================================================
    // Interface <-> top-level engine signals
    // ============================================================
    logic        ifc_start_pulse;
    logic        ifc_abort_pulse;
    logic [15:0] ifc_cfg_N, ifc_cfg_D;
    logic        ifc_engine_busy, ifc_engine_done, ifc_engine_err;

    logic [15:0] ifc_eng_axis_tdata;
    logic        ifc_eng_axis_tvalid;
    logic        ifc_eng_axis_tready;
    logic        ifc_eng_axis_tlast;

    logic [31:0] ifc_c_axis_tdata;
    logic        ifc_c_axis_tvalid;
    logic        ifc_c_axis_tready;
    logic        ifc_c_axis_tlast;

    qkt_interface u_ifc (
        .clk             (clk),
        .rst             (rst),
        .s_axi_awaddr    (s_axi_awaddr),
        .s_axi_awvalid   (s_axi_awvalid),
        .s_axi_awready   (s_axi_awready),
        .s_axi_wdata     (s_axi_wdata),
        .s_axi_wstrb     (s_axi_wstrb),
        .s_axi_wvalid    (s_axi_wvalid),
        .s_axi_wready    (s_axi_wready),
        .s_axi_bresp     (s_axi_bresp),
        .s_axi_bvalid    (s_axi_bvalid),
        .s_axi_bready    (s_axi_bready),
        .s_axi_araddr    (s_axi_araddr),
        .s_axi_arvalid   (s_axi_arvalid),
        .s_axi_arready   (s_axi_arready),
        .s_axi_rdata     (s_axi_rdata),
        .s_axi_rresp     (s_axi_rresp),
        .s_axi_rvalid    (s_axi_rvalid),
        .s_axi_rready    (s_axi_rready),

        .s_axis_tdata    (s_axis_tdata),
        .s_axis_tvalid   (s_axis_tvalid),
        .s_axis_tready   (s_axis_tready),
        .s_axis_tlast    (s_axis_tlast),

        .m_axis_tdata    (m_axis_tdata),
        .m_axis_tvalid   (m_axis_tvalid),
        .m_axis_tready   (m_axis_tready),
        .m_axis_tlast    (m_axis_tlast),

        .start_pulse     (ifc_start_pulse),
        .abort_pulse     (ifc_abort_pulse),
        .cfg_N           (ifc_cfg_N),
        .cfg_D           (ifc_cfg_D),
        .engine_busy     (ifc_engine_busy),
        .engine_done     (ifc_engine_done),
        .engine_err      (ifc_engine_err),
        .eng_axis_tdata  (ifc_eng_axis_tdata),
        .eng_axis_tvalid (ifc_eng_axis_tvalid),
        .eng_axis_tready (ifc_eng_axis_tready),
        .eng_axis_tlast  (ifc_eng_axis_tlast),
        .c_axis_tdata    (ifc_c_axis_tdata),
        .c_axis_tvalid   (ifc_c_axis_tvalid),
        .c_axis_tready   (ifc_c_axis_tready),
        .c_axis_tlast    (ifc_c_axis_tlast)
    );

    // ============================================================
    // Double-buffered Q/K storage
    // q_buf[bank][index], k_buf[bank][index]
    // ============================================================
    logic [15:0] q_buf [2][N*D];
    logic [15:0] k_buf [2][N*D];

    // One-bit bank pointers. Invariant: compute_bank != load_bank.
    logic        compute_bank;   // which bank diagonal_driver reads from
    logic        load_bank;      // which bank load_fsm writes into

    // ============================================================
    // Load FSM (writes into load_bank)
    // ============================================================
    typedef enum logic [2:0] {
        L_IDLE      = 3'd0,
        L_LOAD_Q    = 3'd1,   // accept 16 Q beats from AXI-Stream
        L_COPY_Q    = 3'd2,   // P0: copy Q from other bank (no AXI needed)
        L_LOAD_K    = 3'd3,   // accept 16 K beats from AXI-Stream
        L_DONE      = 3'd4    // wait for compute side to be ready to swap
    } load_state_e;

    load_state_e load_state;
    logic [4:0]  load_cnt;
    logic [4:0]  copy_cnt;

    // What tile the load FSM is currently preparing.
    logic [1:0]  load_tile_r, load_tile_c;

    // Edge case: very first tile (load_tile_r==0, load_tile_c==0) needs Q
    // from AXI. All subsequent tc==0 cases also need Q from AXI. tc>0
    // cases reuse Q from the other bank (P0). We track this with a flag
    // so the FSM transition is unambiguous.
    logic need_q_axi_load;
    assign need_q_axi_load = (load_tile_c == 2'd0);

    // ============================================================
    // Compute FSM (reads from compute_bank)
    // ============================================================
    typedef enum logic [2:0] {
        C_IDLE      = 3'd0,
        C_CLEAR     = 3'd1,
        C_COMPUTE   = 3'd2,
        C_DRAIN     = 3'd3,
        C_DONE      = 3'd4    // wait for load side to be ready to swap
    } comp_state_e;

    comp_state_e comp_state;
    logic [5:0]  compute_cnt;
    logic [4:0]  drain_cnt;

    // What tile the compute FSM is currently working on.
    logic [1:0]  comp_tile_r, comp_tile_c;

    // captured tile result
    logic [31:0] c_tile [N*N];

    // ============================================================
    // Engine started? overall progress?
    // ============================================================
    logic        engine_started;     // set on START, cleared after final swap
    logic        all_tiles_loaded;   // last tile's data has been loaded
    logic        all_tiles_computed; // last tile's drain has completed
    logic        done_pulse;

    // engine_busy true while any work is in flight
    assign ifc_engine_busy = engine_started || (comp_state != C_IDLE) || (load_state != L_IDLE);
    assign ifc_engine_err  = 1'b0;
    assign ifc_engine_done = done_pulse;

    // AXI-Stream input ready: only during the LOAD_Q / LOAD_K substates
    assign ifc_eng_axis_tready = (load_state == L_LOAD_Q) || (load_state == L_LOAD_K);

    // ============================================================
    // Bank-swap barrier
    //
    // We swap banks when:
    //   - load FSM has reached L_DONE (filled load_bank for next tile), AND
    //   - compute FSM has reached C_DONE or C_IDLE (compute_bank is free)
    //
    // On swap:
    //   compute_bank <= load_bank;
    //   load_bank    <= ~load_bank;
    //   load FSM advances to next-next tile coords and starts L_LOAD_Q/COPY_Q
    //   compute FSM advances to next tile coords and starts C_CLEAR
    // ============================================================
    logic do_swap;
    assign do_swap = (load_state == L_DONE)
                  && ((comp_state == C_DONE) || (comp_state == C_IDLE));

    // ============================================================
    // Diagonal-skew driver (combinational): reads from q_buf[compute_bank]
    // and k_buf[compute_bank]. Identical math to M3, just bank-indexed.
    // ============================================================
    logic [N*16-1:0] q_in_bus;
    logic [N*16-1:0] k_in_bus;
    logic            core_en;
    logic            core_clear;

    always_comb begin
        q_in_bus = '0;
        k_in_bus = '0;
        for (int i = 0; i < N; i++) begin
            int didx_q;
            didx_q = int'(compute_cnt) - i;
            if ((didx_q >= 0) && (didx_q < D))
                q_in_bus[i*16 +: 16] = q_buf[compute_bank][i*D + didx_q];
        end
        for (int j = 0; j < N; j++) begin
            int didx_k;
            didx_k = int'(compute_cnt) - j;
            if ((didx_k >= 0) && (didx_k < D))
                k_in_bus[j*16 +: 16] = k_buf[compute_bank][j*D + didx_k];
        end
    end

    assign core_en    = (comp_state == C_COMPUTE);
    assign core_clear = (comp_state == C_CLEAR);

    logic [N*N*32-1:0] c_out_bus;

    compute_core #(.N(N), .D(D)) u_core (
        .clk       (clk),
        .rst       (rst),
        .clear     (core_clear),
        .en        (core_en),
        .q_in_bus  (q_in_bus),
        .k_in_bus  (k_in_bus),
        .c_out_bus (c_out_bus)
    );

    // ============================================================
    // Load FSM sequential block
    // ============================================================
    always_ff @(posedge clk) begin : load_fsm
        if (rst) begin
            load_state    <= L_IDLE;
            load_cnt      <= 5'd0;
            copy_cnt      <= 5'd0;
            load_tile_r   <= 2'd0;
            load_tile_c   <= 2'd0;
            load_bank     <= 1'b1;     // bank 1 is initial load target;
                                       // bank 0 is initial compute target
            all_tiles_loaded <= 1'b0;
        end else if (ifc_abort_pulse) begin
            load_state    <= L_IDLE;
            load_cnt      <= 5'd0;
            load_tile_r   <= 2'd0;
            load_tile_c   <= 2'd0;
            load_bank     <= 1'b1;
            all_tiles_loaded <= 1'b0;
        end else begin
            case (load_state)
                L_IDLE: begin
                    if (ifc_start_pulse) begin
                        // Start loading tile (0,0) into bank 0 first.
                        // We override load_bank to 0 here so the FIRST
                        // load lands in bank 0 (which is compute_bank=0
                        // initially). On the first "swap" we'll flip
                        // both: compute_bank=0 stays receiving the just-
                        // loaded data, load_bank becomes 1 for tile (0,1).
                        // See do_swap logic below.
                        //
                        // Tile (0,0) needs a real Q load from AXI.
                        load_bank    <= 1'b0;
                        load_tile_r  <= 2'd0;
                        load_tile_c  <= 2'd0;
                        load_cnt     <= 5'd0;
                        load_state   <= L_LOAD_Q;  // tile (0,0): tc==0, need AXI Q
                    end
                end

                L_LOAD_Q: begin
                    if (ifc_eng_axis_tvalid && ifc_eng_axis_tready) begin
                        q_buf[load_bank][load_cnt] <= ifc_eng_axis_tdata;
                        if (load_cnt == BEATS_PER_LOAD - 1) begin
                            load_cnt   <= 5'd0;
                            load_state <= L_LOAD_K;
                        end else begin
                            load_cnt <= load_cnt + 5'd1;
                        end
                    end
                end

                L_COPY_Q: begin
                    // Q-row reuse (P0 within P1): copy Q from the other
                    // bank in one beat per cycle. This bridges the gap
                    // that bank-A's Q can't directly serve a bank-B
                    // compute. After COPY_Q completes, the new load_bank
                    // has the same Q data as the bank we just swapped
                    // FROM. Cheap (16 cycles, ~0 AXI traffic).
                    q_buf[load_bank][copy_cnt] <= q_buf[~load_bank][copy_cnt];
                    if (copy_cnt == BEATS_PER_LOAD - 1) begin
                        copy_cnt   <= 5'd0;
                        load_state <= L_LOAD_K;
                    end else begin
                        copy_cnt <= copy_cnt + 5'd1;
                    end
                end

                L_LOAD_K: begin
                    if (ifc_eng_axis_tvalid && ifc_eng_axis_tready) begin
                        k_buf[load_bank][load_cnt] <= ifc_eng_axis_tdata;
                        if (load_cnt == BEATS_PER_LOAD - 1) begin
                            load_cnt   <= 5'd0;
                            // Check if this was the last tile.
                            if ((load_tile_r == NUM_TILES_PER_DIM - 1) &&
                                (load_tile_c == NUM_TILES_PER_DIM - 1)) begin
                                all_tiles_loaded <= 1'b1;
                                load_state <= L_DONE;
                            end else begin
                                load_state <= L_DONE;
                            end
                        end else begin
                            load_cnt <= load_cnt + 5'd1;
                        end
                    end
                end

                L_DONE: begin
                    // Wait for the swap. On swap, advance to the next
                    // tile (the one AFTER what we just finished loading).
                    if (do_swap) begin
                        load_bank <= ~load_bank;  // flip to the new free bank
                        if (all_tiles_loaded) begin
                            // No more tiles to load; go idle.
                            load_state <= L_IDLE;
                        end else begin
                            // Advance load_tile coords.
                            if (load_tile_c == NUM_TILES_PER_DIM - 1) begin
                                load_tile_c <= 2'd0;
                                load_tile_r <= load_tile_r + 2'd1;
                                load_state  <= L_LOAD_Q;  // new row-band: AXI Q
                            end else begin
                                load_tile_c <= load_tile_c + 2'd1;
                                // tc>0: P0 Q-reuse via copy from old bank
                                load_state  <= L_COPY_Q;
                            end
                        end
                    end
                end

                default: load_state <= L_IDLE;
            endcase
        end
    end

    // ============================================================
    // Compute FSM sequential block
    // ============================================================
    always_ff @(posedge clk) begin : compute_fsm
        if (rst) begin
            comp_state    <= C_IDLE;
            compute_cnt   <= 6'd0;
            drain_cnt     <= 5'd0;
            comp_tile_r   <= 2'd0;
            comp_tile_c   <= 2'd0;
            compute_bank  <= 1'b0;
            engine_started     <= 1'b0;
            all_tiles_computed <= 1'b0;
            done_pulse    <= 1'b0;
            ifc_c_axis_tvalid <= 1'b0;
            ifc_c_axis_tlast  <= 1'b0;
            ifc_c_axis_tdata  <= 32'd0;
            for (int k = 0; k < N*N; k++) c_tile[k] <= 32'd0;
        end else if (ifc_abort_pulse) begin
            comp_state    <= C_IDLE;
            compute_cnt   <= 6'd0;
            drain_cnt     <= 5'd0;
            comp_tile_r   <= 2'd0;
            comp_tile_c   <= 2'd0;
            compute_bank  <= 1'b0;
            engine_started     <= 1'b0;
            all_tiles_computed <= 1'b0;
            ifc_c_axis_tvalid <= 1'b0;
        end else begin
            done_pulse <= 1'b0;

            // Default: drop tvalid after a handshake.
            if (ifc_c_axis_tvalid && ifc_c_axis_tready) begin
                ifc_c_axis_tvalid <= 1'b0;
                ifc_c_axis_tlast  <= 1'b0;
            end

            case (comp_state)
                C_IDLE: begin
                    if (ifc_start_pulse) begin
                        engine_started <= 1'b1;
                        // Don't enter C_CLEAR yet -- wait for first swap
                        // (which gives us a freshly loaded compute_bank).
                        // comp_state stays C_IDLE.
                    end
                    // First-swap detection: when load FSM finishes the
                    // first tile and lands in L_DONE, do_swap fires and
                    // we'll see compute_bank == load_bank initially (both
                    // start at 0). The swap below flips load_bank to 1
                    // and starts us computing on bank 0.
                    if (do_swap) begin
                        comp_state  <= C_CLEAR;
                        comp_tile_r <= 2'd0;
                        comp_tile_c <= 2'd0;
                        // compute_bank stays 0 (the bank just loaded)
                    end
                end

                C_CLEAR: begin
                    comp_state  <= C_COMPUTE;
                    compute_cnt <= 6'd0;
                end

                C_COMPUTE: begin
                    compute_cnt <= compute_cnt + 6'd1;
                    if (compute_cnt == COMPUTE_TOTAL - 1) begin
                        for (int k = 0; k < N*N; k++)
                            c_tile[k] <= c_out_bus[k*32 +: 32];
                        comp_state <= C_DRAIN;
                        drain_cnt  <= 5'd0;
                    end
                end

                C_DRAIN: begin
                    if (!ifc_c_axis_tvalid || ifc_c_axis_tready) begin
                        ifc_c_axis_tdata  <= c_tile[drain_cnt];
                        ifc_c_axis_tvalid <= 1'b1;
                        ifc_c_axis_tlast  <= (drain_cnt == N*N - 1);
                        if (drain_cnt == N*N - 1) begin
                            drain_cnt <= 5'd0;
                            // Check if this was the last tile to compute.
                            if ((comp_tile_r == NUM_TILES_PER_DIM - 1) &&
                                (comp_tile_c == NUM_TILES_PER_DIM - 1)) begin
                                all_tiles_computed <= 1'b1;
                                done_pulse <= 1'b1;
                                engine_started <= 1'b0;
                                comp_state <= C_IDLE;
                            end else begin
                                comp_state <= C_DONE;
                            end
                        end else begin
                            drain_cnt <= drain_cnt + 5'd1;
                        end
                    end
                end

                C_DONE: begin
                    // Wait for swap. On swap, advance compute_bank to
                    // the just-loaded bank and advance comp_tile coords.
                    if (do_swap) begin
                        compute_bank <= load_bank;  // flip to fresh data
                        if (comp_tile_c == NUM_TILES_PER_DIM - 1) begin
                            comp_tile_c <= 2'd0;
                            comp_tile_r <= comp_tile_r + 2'd1;
                        end else begin
                            comp_tile_c <= comp_tile_c + 2'd1;
                        end
                        comp_state <= C_CLEAR;
                    end
                end

                default: comp_state <= C_IDLE;
            endcase
        end
    end

    // Reference cfg_N / cfg_D so iverilog doesn't warn (configurable in M4).
    logic unused;
    assign unused = |{ifc_cfg_N, ifc_cfg_D, all_tiles_computed};

endmodule

`default_nettype wire
