// =============================================================================
// File   : core_pe.sv  (M4 v2: tree-reduce + d-dim chaining)
// Module : core_pe
//
// Per-PE compute element that supports d-dimension chaining: accumulates
// over multiple D-blocks within one output tile before emitting acc_out.
//
// Pipeline of operations per output tile:
//   For block 0 .. N_BLOCKS-1:
//     1. Collect 4 products into prod_buf  (4 cycles of valid_in)
//     2. Tree-reduce via fp32_adder_pipelined  -> block_sum
//     3. If first block:    tile_acc <= block_sum
//        Else:              tile_acc <= fp32_add(tile_acc, block_sum)  [chain-add]
//     4. If block_last:     acc_out  <= tile_acc
//
// New ports vs v1
// ----------------
//   block_first  : asserted by top.sv during the FIRST d-block of each tile.
//                  PE uses this to seed tile_acc directly (no chain-add).
//   block_last   : asserted during the LAST d-block. PE captures tile_acc
//                  into acc_out at the end of that block.
//   block_clear  : soft clear between consecutive d-blocks of the same tile.
//                  Resets prod_buf, prod_count, reduce_cnt, s01/s23 regs,
//                  and the adder pipeline. Does NOT touch tile_acc.
//   clear        : hard clear at tile boundary. Resets EVERYTHING including
//                  tile_acc and acc_out.
//
// Adder sharing
// -------------
// The single fp32_adder_pipelined is reused across two phases per block:
//   - Phase A (tree-reduce): cycles K+5, K+6 launch (p0+p1), (p2+p3);
//     cycle K+10 launches (s01+s23) which produces block_sum at K+13.
//   - Phase B (chain-add):   cycle K+14 launches (tile_acc + block_sum);
//     tile_acc updates at K+17.
// Since block_clear is pulsed after K+17 by top.sv (with a small margin),
// the adder pipeline is empty before the next block reuses it. The
// block-to-block period is ~21 cycles at the worst-case PE [N-1][N-1].
// =============================================================================

`default_nettype none

module core_pe (
    input  logic        clk,
    input  logic        rst,
    input  logic        clear,        // hard clear, tile boundary
    input  logic        block_clear,  // soft clear, between d-blocks
    input  logic        block_first,  // this d-block is first of a tile
    input  logic        block_last,   // this d-block is last of a tile
    input  logic        en,
    input  logic        valid_in,
    input  logic [15:0] a_in,
    input  logic [15:0] b_in,
    output logic        valid_out,
    output logic [15:0] a_out,
    output logic [15:0] b_out,
    output logic [31:0] acc_out
);

    // Latch block_first/block_last edge-triggered so the FSM uses a stable copy
    // across the block. Top.sv asserts these for the duration of the block.
    logic block_first_q, block_last_q;

    always_ff @(posedge clk) begin
        if (rst || clear) begin
            block_first_q <= 1'b0;
            block_last_q  <= 1'b0;
        end else begin
            block_first_q <= block_first;
            block_last_q  <= block_last;
        end
    end

    // ============================================================
    // Multiplier (combinational) + 1-cycle product register
    // ============================================================
    logic [31:0] product_fp32;
    fp16_multiplier u_mul (
        .a      (a_in),
        .b      (b_in),
        .result (product_fp32)
    );

    logic [31:0] product_q;
    logic        valid_q;

    always_ff @(posedge clk) begin
        if (rst || clear || block_clear) begin
            product_q <= 32'h0;
            valid_q   <= 1'b0;
            a_out     <= 16'h0;
            b_out     <= 16'h0;
            valid_out <= 1'b0;
        end else begin
            product_q <= product_fp32;
            valid_q   <= valid_in;
            a_out     <= a_in;
            b_out     <= b_in;
            valid_out <= valid_in;
        end
    end

    // ============================================================
    // Product buffer (4 entries, one per cycle of valid_in)
    // ============================================================
    logic [31:0] prod_buf [4];
    logic [2:0]  prod_count;
    logic        prod_full;
    assign prod_full = (prod_count == 3'd4);

    always_ff @(posedge clk) begin
        if (rst || clear || block_clear) begin
            for (int i = 0; i < 4; i++) prod_buf[i] <= 32'h0;
            prod_count <= 3'd0;
        end else if (valid_q && !prod_full) begin
            prod_buf[prod_count[1:0]] <= product_q;
            prod_count                <= prod_count + 3'd1;
        end
    end

    // ============================================================
    // Reduce sequencer
    //
    // Phase A (tree-reduce): same as v1 design.
    //   reduce_cnt=0: launch (prod[0], prod[1])
    //   reduce_cnt=1: launch (prod[2], prod[3])
    //   reduce_cnt=3: capture s01
    //   reduce_cnt=4: capture s23
    //   reduce_cnt=5: launch (s01, s23)
    //   reduce_cnt=8: capture block_sum
    //
    // Phase B (chain-add, only for non-first blocks):
    //   reduce_cnt=9:  launch (tile_acc, block_sum)
    //   reduce_cnt=12: capture chain result into tile_acc
    //
    // For first blocks (no chain-add):
    //   reduce_cnt=9:  tile_acc <= block_sum (direct seed)
    //
    // For last block: at end of phase B (or phase A for first+last single-block
    // tiles, but that's an edge case we still support), copy tile_acc to acc_out.
    // ============================================================
    logic [3:0] reduce_cnt;

    always_ff @(posedge clk) begin
        if (rst || clear || block_clear) begin
            reduce_cnt <= 4'd0;
        end else if (prod_full && reduce_cnt != 4'd15) begin
            reduce_cnt <= reduce_cnt + 4'd1;
        end
    end

    // ============================================================
    // Adder driver and instance
    // ============================================================
    logic [31:0] add_a, add_b;
    logic        add_valid_in;

    logic [31:0] s01_reg, s23_reg, block_sum_reg, tile_acc;

    always_comb begin
        add_a        = 32'h0;
        add_b        = 32'h0;
        add_valid_in = 1'b0;

        if (prod_full) begin
            unique case (reduce_cnt)
                // Phase A: tree-reduce
                4'd0: begin add_a = prod_buf[0]; add_b = prod_buf[1]; add_valid_in = 1'b1; end
                4'd1: begin add_a = prod_buf[2]; add_b = prod_buf[3]; add_valid_in = 1'b1; end
                4'd5: begin add_a = s01_reg;     add_b = s23_reg;     add_valid_in = 1'b1; end
                // Phase B: chain-add (only when not first block)
                4'd9: begin
                    if (!block_first_q) begin
                        add_a        = tile_acc;
                        add_b        = block_sum_reg;
                        add_valid_in = 1'b1;
                    end
                end
                default: ;
            endcase
        end
    end

    logic [31:0] add_sum;
    logic        add_valid_out;

    fp32_adder_pipelined u_add (
        .clk       (clk),
        .rst       (rst || clear || block_clear),
        .valid_in  (add_valid_in),
        .a         (add_a),
        .b         (add_b),
        .valid_out (add_valid_out),
        .sum       (add_sum)
    );

    // ============================================================
    // Result capture
    //   reduce_cnt=3: latch s01
    //   reduce_cnt=4: latch s23
    //   reduce_cnt=8: latch block_sum (output of tree-reduce)
    //   reduce_cnt=9 first-block: seed tile_acc with block_sum
    //   reduce_cnt=12 non-first-block: latch chain result into tile_acc
    //   reduce_cnt=12 (or 9 for first block) AND block_last_q:
    //                  copy tile_acc to acc_out
    // ============================================================
    always_ff @(posedge clk) begin
        if (rst || clear) begin
            s01_reg       <= 32'h0;
            s23_reg       <= 32'h0;
            block_sum_reg <= 32'h0;
            tile_acc      <= 32'h0;
            acc_out       <= 32'h0;
        end else begin
            // Phase A intermediates and block_sum: latched even across blocks
            // (they get reset by block_clear via reduce_cnt anyway)
            if (reduce_cnt == 4'd3 && add_valid_out) s01_reg       <= add_sum;
            if (reduce_cnt == 4'd4 && add_valid_out) s23_reg       <= add_sum;
            if (reduce_cnt == 4'd8 && add_valid_out) block_sum_reg <= add_sum;

            // Tile-level accumulator update
            if (reduce_cnt == 4'd9 && block_first_q) begin
                // First block: seed tile_acc directly (no chain-add)
                tile_acc <= block_sum_reg;
            end else if (reduce_cnt == 4'd12 && add_valid_out && !block_first_q) begin
                // Subsequent blocks: chain-add result
                tile_acc <= add_sum;
            end

            // Output capture on the last block
            if (block_last_q) begin
                if (reduce_cnt == 4'd9 && block_first_q) begin
                    // First-AND-last block case (e.g., d_head == D)
                    acc_out <= block_sum_reg;
                end else if (reduce_cnt == 4'd12 && !block_first_q) begin
                    // Normal last-block case
                    acc_out <= add_sum;
                end
            end
        end
    end

endmodule

`default_nettype wire
