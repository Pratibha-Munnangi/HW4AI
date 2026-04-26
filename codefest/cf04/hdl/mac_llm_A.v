module mac (
    input  logic              clk,
    input  logic              rst,        // active-high synchronous reset
    input  logic signed [7:0] a,
    input  logic signed [7:0] b,
    output logic signed [31:0] out
);
    // Internal multiplication result
    logic signed [15:0] mult;
    // Combinational multiply
    assign mult = a * b;
    // Sequential MAC operation
    always_ff @(posedge clk) begin
        if (rst) begin
            out <= 32'sd0;
        end else begin
            out <= out + mult;
        end
    end
endmodule
