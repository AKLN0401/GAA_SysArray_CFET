// Output-stationary INT8 MAC processing element.
// a_i flows right, b_i flows down; acc_o accumulates a*b (signed).
module sysarr_pe #(
  parameter int AW   = 8,
  parameter int ACCW = 32
) (
  input  logic                    clk_i,
  input  logic                    rst_ni,
  input  logic                    clear_i,   // synchronous: zero acc and pipeline regs
  input  logic                    en_i,      // advance one step
  input  logic signed [AW-1:0]    a_i,
  input  logic signed [AW-1:0]    b_i,
  output logic signed [AW-1:0]    a_o,
  output logic signed [AW-1:0]    b_o,
  output logic signed [ACCW-1:0]  acc_o
);
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      a_o   <= '0;
      b_o   <= '0;
      acc_o <= '0;
    end else if (clear_i) begin
      a_o   <= '0;
      b_o   <= '0;
      acc_o <= '0;
    end else if (en_i) begin
      a_o   <= a_i;
      b_o   <= b_i;
      acc_o <= acc_o + ACCW'(a_i) * ACCW'(b_i);   // sign-extend before multiply
    end
  end
endmodule
