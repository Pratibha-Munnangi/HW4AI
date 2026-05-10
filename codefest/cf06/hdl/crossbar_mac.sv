//-----------------------------------------------------------------------------
// crossbar_mac.sv
// 4x4 binary-weight crossbar MAC unit
//
// Computes: out[j] = sum over i of (weight[i][j] * in[i]) for j in 0..3
//
// Weights are encoded as +1 / -1 using a single bit per cell:
//   weight_bit = 1  -> +1
//   weight_bit = 0  -> -1
//
// Inputs  : 4 lanes, each 8-bit signed
// Outputs : 4 lanes, accumulator width chosen wide enough to avoid overflow.
//   Worst case per output: |sum| <= 4 * 127 = 508, fits comfortably in 12 bits
//   signed. We use 16-bit signed for headroom and easy waveform inspection.
//
// One result is produced each clock cycle (synchronous, registered output).
//-----------------------------------------------------------------------------
module crossbar_mac #(
    parameter int N        = 4,    // crossbar dimension (N x N)
    parameter int IN_W     = 8,    // input bit-width (signed)
    parameter int ACC_W    = 16    // accumulator bit-width (signed)
) (
    input  logic                       clk,
    input  logic                       rst_n,        // active-low sync reset
    input  logic                       load_w,       // pulse high to load weights
    input  logic [N-1:0][N-1:0]        w_bits_in,    // [row][col] weight bits
    input  logic signed [IN_W-1:0]     in_vec  [N],  // input vector
    // Output vector packed flat: out_vec_flat[(j+1)*ACC_W-1 : j*ACC_W] = out[j]
    // (Packed for maximum simulator/tool portability; semantically still N
    //  signed accumulators of width ACC_W.)
    output logic signed [N*ACC_W-1:0]  out_vec_flat
);

    // Convenience handle for internal use
    logic signed [ACC_W-1:0] out_vec [N];
    genvar gflat;
    generate
        for (gflat = 0; gflat < N; gflat++) begin : g_flatten
            assign out_vec_flat[(gflat+1)*ACC_W-1 -: ACC_W] = out_vec[gflat];
        end
    endgenerate

    // Weight register array: 1 bit per cell. weight_reg[i][j].
    logic [N-1:0][N-1:0] weight_reg;

    // -------------------------------------------------------------------------
    // Weight load
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n)        weight_reg <= '0;
        else if (load_w)   weight_reg <= w_bits_in;
    end

    // -------------------------------------------------------------------------
    // Combinational column sums (one per output)
    //
    // For each column j, sum signed contributions from every row i:
    //   contribution = (weight_reg[i][j] ? +in[i] : -in[i])
    //
    // Built with a generate block so the per-cell contributions become
    // structural nets -- this matches what physical synthesis would produce
    // (one signed adder/subtractor per cell, fed into an N-input column tree).
    // -------------------------------------------------------------------------
    logic signed [ACC_W-1:0] contrib  [N][N];
    logic signed [ACC_W-1:0] col_sum  [N];

    genvar gi, gj;
    generate
        for (gj = 0; gj < N; gj++) begin : g_col
            for (gi = 0; gi < N; gi++) begin : g_row
                assign contrib[gi][gj] = weight_reg[gi][gj]
                                       ?  ACC_W'(in_vec[gi])
                                       : -ACC_W'(in_vec[gi]);
            end
            // Sum the N row contributions for this column
            assign col_sum[gj] = contrib[0][gj]
                               + contrib[1][gj]
                               + contrib[2][gj]
                               + contrib[3][gj];
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Registered output (one cycle latency from in_vec to out_vec)
    // Loop unrolled with a generate block for clean simulator behavior
    // across tools (some sims have quirks with non-blocking writes to
    // unpacked array ports inside `for` loops).
    // -------------------------------------------------------------------------
    genvar gout;
    generate
        for (gout = 0; gout < N; gout++) begin : g_out_reg
            always_ff @(posedge clk) begin
                if (!rst_n) out_vec[gout] <= '0;
                else        out_vec[gout] <= col_sum[gout];
            end
        end
    endgenerate

endmodule
