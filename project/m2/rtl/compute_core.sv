`default_nettype none

module compute_core #(
    parameter int N = 4,
    parameter int D = 4
) (
    input  logic                       clk,
    input  logic                       rst,
    input  logic                       en,

    // Packed bus inputs: q_in_bus[i*16 +: 16] = Q row i operand at this cycle.
    input  logic [N*16-1:0]            q_in_bus,
    input  logic [N*16-1:0]            k_in_bus,

    // Packed bus output: c_out_bus[(i*N + j)*32 +: 32] = C[i][j] FP32.
    output logic [N*N*32-1:0]          c_out_bus
);

    // Decompose the input buses into per-row/column FP16 wires.
    logic [15:0] q_row [N];
    logic [15:0] k_col [N];

    genvar gx;
    generate
        for (gx = 0; gx < N; gx++) begin : gen_io
            assign q_row[gx] = q_in_bus[gx*16 +: 16];
            assign k_col[gx] = k_in_bus[gx*16 +: 16];
        end
    endgenerate

    // Inter-PE forwarding.
    logic [15:0] a_wire   [N][N];
    logic [15:0] b_wire   [N][N];
    logic [15:0] a_fwd    [N][N];
    logic [15:0] b_fwd    [N][N];
    logic [31:0] acc_grid [N][N];

    genvar gi, gj;
    generate
        for (gi = 0; gi < N; gi++) begin : gen_row
            for (gj = 0; gj < N; gj++) begin : gen_col

                if (gj == 0)
                    assign a_wire[gi][gj] = q_row[gi];
                else
                    assign a_wire[gi][gj] = a_fwd[gi][gj-1];

                if (gi == 0)
                    assign b_wire[gi][gj] = k_col[gj];
                else
                    assign b_wire[gi][gj] = b_fwd[gi-1][gj];

                core_pe u_pe (
                    .clk     (clk),
                    .rst     (rst),
                    .en      (en),
                    .a_in    (a_wire[gi][gj]),
                    .b_in    (b_wire[gi][gj]),
                    .a_out   (a_fwd  [gi][gj]),
                    .b_out   (b_fwd  [gi][gj]),
                    .acc_out (acc_grid[gi][gj])
                );

            end : gen_col
        end : gen_row
    endgenerate

    // Pack acc_grid into the output bus.
    genvar gi2, gj2;
    generate
        for (gi2 = 0; gi2 < N; gi2++) begin : gen_pack_row
            for (gj2 = 0; gj2 < N; gj2++) begin : gen_pack_col
                assign c_out_bus[(gi2*N + gj2)*32 +: 32] = acc_grid[gi2][gj2];
            end
        end
    endgenerate

endmodule

`default_nettype wire
