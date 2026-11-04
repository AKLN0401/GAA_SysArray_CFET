// Self-checking testbench for npu_acc (N=8 by default). Random A,B, three runs, plus
// corner values (-128 * -128) and a write-while-busy check.
`timescale 1ns/1ps
module tb_npu_acc;
  localparam int N = 8;
  logic clk = 0, rst_n = 0;
  logic req = 0, we = 0; logic [3:0] be = 4'hF; logic [31:0] addr = 0, wdata = 0;
  logic gnt, rvalid; logic [31:0] rdata;
  always #5 clk = ~clk;

  npu_acc #(.N(N)) dut (.clk_i(clk), .rst_ni(rst_n), .req_i(req), .we_i(we), .be_i(be),
                        .addr_i(addr), .wdata_i(wdata), .gnt_o(gnt), .rvalid_o(rvalid), .rdata_o(rdata));

  int errors = 0;
  logic signed [7:0] A [N][N], B [N][N];

  task automatic wr(input logic [31:0] a, input logic [31:0] d, input logic [3:0] b = 4'hF);
    @(negedge clk); req = 1; we = 1; addr = a; wdata = d; be = b;
    @(negedge clk); req = 0; we = 0;
  endtask
  task automatic rd(input logic [31:0] a, output logic [31:0] d);
    @(negedge clk); req = 1; we = 0; addr = a;
    @(negedge clk); req = 0;
    if (!rvalid) begin $display("FAIL: rvalid missing"); errors++; end
    d = rdata;
  endtask

  task automatic load_and_run(input bit corner);
    logic [31:0] w, st; int c, timeout;
    for (int i = 0; i < N; i++) for (int k = 0; k < N; k++) begin
      A[i][k] = corner ? -8'sd128 : $signed(8'($urandom));
      B[i][k] = corner ? -8'sd128 : $signed(8'($urandom));
    end
    for (int wd = 0; wd < (N*N)/4; wd++) begin
      logic [31:0] aw, bw;
      for (int b = 0; b < 4; b++) begin
        int e = wd*4 + b;
        aw[8*b +: 8] = A[e/N][e%N];
        bw[8*b +: 8] = B[e/N][e%N];
      end
      wr(32'h100 + 4*wd, aw);
      wr(32'h200 + 4*wd, bw);
    end
    wr(32'h000, 32'd1);                       // start
    // write while busy must be ignored
    wr(32'h100, 32'hDEADBEEF);
    timeout = 0;
    do begin rd(32'h004, st); timeout++; end while (!st[1] && timeout < 100);
    if (timeout >= 100) begin $display("FAIL: timeout"); errors++; end
    for (int i = 0; i < N; i++) for (int j = 0; j < N; j++) begin
      int exp = 0;
      for (int k = 0; k < N; k++) exp += int'(A[i][k]) * int'(B[k][j]);
      rd(32'h300 + 4*(i*N+j), w);
      if ($signed(w) !== exp) begin
        $display("FAIL C[%0d][%0d] got %0d exp %0d", i, j, $signed(w), exp); errors++;
      end
    end
  endtask

  initial begin
    logic [31:0] info;
    repeat (3) @(negedge clk); rst_n = 1; repeat (2) @(negedge clk);
    rd(32'h008, info);
    if (info[7:0] !== N || info[15:8] !== 8 || info[23:16] !== 32) begin
      $display("FAIL INFO %h", info); errors++;
    end
    load_and_run(0);
    load_and_run(0);
    load_and_run(1);
    if (errors == 0) $display("PASS: npu_acc N=%0d, 3 runs", N);
    else             $display("FAILED: %0d errors", errors);
    $finish;
  end
endmodule
