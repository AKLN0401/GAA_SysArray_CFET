// N x N output-stationary systolic array. Row i takes a_edge_i[i] at its left edge,
// column j takes b_edge_i[j] at its top edge. Inputs must be skewed by the controller.
module sysarr #(
  parameter int N    = 4,
  parameter int AW   = 8,
  parameter int ACCW = 32
) (
  input  logic                    clk_i,
  input  logic                    rst_ni,
  input  logic                    clear_i,
  input  logic                    en_i,
  input  logic [N*AW-1:0]         a_edge_i,   // row i  : [AW*i +: AW]
  input  logic [N*AW-1:0]         b_edge_i,   // col j  : [AW*j +: AW]
  output logic [N*N*ACCW-1:0]     c_o         // C[i][j]: [ACCW*(i*N+j) +: ACCW]
);
  logic signed [AW-1:0] a_w [N][N+1];
  logic signed [AW-1:0] b_w [N+1][N];

  for (genvar i = 0; i < N; i++) begin : g_edge_a
    assign a_w[i][0] = a_edge_i[AW*i +: AW];
  end
  for (genvar j = 0; j < N; j++) begin : g_edge_b
    assign b_w[0][j] = b_edge_i[AW*j +: AW];
  end

  for (genvar i = 0; i < N; i++) begin : g_row
    for (genvar j = 0; j < N; j++) begin : g_col
      logic signed [ACCW-1:0] acc;
      sysarr_pe #(.AW(AW), .ACCW(ACCW)) u_pe (
        .clk_i, .rst_ni, .clear_i, .en_i,
        .a_i  (a_w[i][j]),
        .b_i  (b_w[i][j]),
        .a_o  (a_w[i][j+1]),
        .b_o  (b_w[i+1][j]),
        .acc_o(acc)
      );
      assign c_o[ACCW*(i*N+j) +: ACCW] = acc;
    end
  end
endmodule
