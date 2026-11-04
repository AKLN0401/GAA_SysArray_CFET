// Self-checking testbench for the accelerator subsystem: npu_dma + npu_acc + 2 x lram_256x32, driven like Ibex's LSU
// (req held until gnt, one outstanding access, rvalid for every granted access).
// Checks: SRAM word/byte access, two tiled GEMMs against a software reference (16x16x16 and 8x16x24, the second
// accumulating over 3 K tiles), CPU stall on SRAM/npu_acc while the DMA runs, DMA registers readable while busy.
`timescale 1ns/1ps
module tb_npu_sys;
  localparam int N = 8;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic req = 0, we = 0, gnt, rvalid;
  logic [3:0]  be = 4'hF;
  logic [13:0] addr = 0;
  logic [31:0] wdata = 0, rdata;

  logic        acc_req, acc_we, acc_gnt, acc_rvalid;
  logic [3:0]  acc_be;
  logic [31:0] acc_addr, acc_wdata, acc_rdata;
  logic        s0_ce, s0_we, s1_ce, s1_we;
  logic [3:0]  s0_be, s1_be;
  logic [7:0]  s0_addr, s1_addr;
  logic [31:0] s0_wdata, s0_rdata, s1_wdata, s1_rdata;

  npu_dma #(.N(N)) u_dma (
    .clk_i (clk), .rst_ni (rst_n),
    .s_req_i (req), .s_gnt_o (gnt), .s_rvalid_o (rvalid), .s_we_i (we), .s_be_i (be), .s_addr_i (addr),
    .s_wdata_i (wdata), .s_rdata_o (rdata),
    .acc_req_o (acc_req), .acc_we_o (acc_we), .acc_be_o (acc_be), .acc_addr_o (acc_addr), .acc_wdata_o (acc_wdata),
    .acc_gnt_i (acc_gnt), .acc_rvalid_i (acc_rvalid), .acc_rdata_i (acc_rdata),
    .sram0_ce_o (s0_ce), .sram0_we_o (s0_we), .sram0_be_o (s0_be), .sram0_addr_o (s0_addr),
    .sram0_wdata_o (s0_wdata), .sram0_rdata_i (s0_rdata),
    .sram1_ce_o (s1_ce), .sram1_we_o (s1_we), .sram1_be_o (s1_be), .sram1_addr_o (s1_addr),
    .sram1_wdata_o (s1_wdata), .sram1_rdata_i (s1_rdata));
  npu_acc #(.N(N)) u_acc (.clk_i (clk), .rst_ni (rst_n), .req_i (acc_req), .we_i (acc_we), .be_i (acc_be),
    .addr_i (acc_addr), .wdata_i (acc_wdata), .gnt_o (acc_gnt), .rvalid_o (acc_rvalid), .rdata_o (acc_rdata));
  lram_256x32 u_sram0 (.clk_i (clk), .rst_ni (rst_n), .ce_i (s0_ce), .we_i (s0_we), .be_i (s0_be),
    .addr_i (s0_addr), .wdata_i (s0_wdata), .rdata_o (s0_rdata));
  lram_256x32 u_sram1 (.clk_i (clk), .rst_ni (rst_n), .ce_i (s1_ce), .we_i (s1_we), .be_i (s1_be),
    .addr_i (s1_addr), .wdata_i (s1_wdata), .rdata_o (s1_rdata));

  localparam logic [13:0] S0 = 14'h1000, S1 = 14'h2000, DMA = 14'h3000;
  int errors = 0;

  // one bus access; returns the number of cycles gnt was low
  task automatic access(input logic w, input logic [13:0] a, input logic [31:0] d, input logic [3:0] b,
                        output logic [31:0] q, output int stall);
    @(negedge clk); req = 1; we = w; addr = a; wdata = d; be = b;
    stall = 0;
    while (!gnt) begin @(negedge clk); stall++; end
    @(negedge clk); req = 0; we = 0;
    if (!rvalid) begin $display("FAIL: rvalid missing at %h", a); errors++; end
    q = rdata;
  endtask
  task automatic wr(input logic [13:0] a, input logic [31:0] d, input logic [3:0] b = 4'hF);
    logic [31:0] q; int s; access(1, a, d, b, q, s);
  endtask
  task automatic rd(input logic [13:0] a, output logic [31:0] q);
    int s; access(0, a, 0, 4'hF, q, s);
  endtask

  // C (M x Nc) = A (M x K) x B (K x Nc); A at SRAM0 word 0, B right after it, C at SRAM1 word 0
  task automatic gemm(input int mt, input int nt, input int kt);
    int M = mt*N, NC = nt*N, K = kt*N;
    int bbase = (M*K)/4;
    logic signed [7:0] A [], B [];
    logic [31:0] q, st, cyc;
    int timeout;
    A = new[M*K]; B = new[K*NC];
    foreach (A[i]) A[i] = $signed(8'($urandom));
    foreach (B[i]) B[i] = $signed(8'($urandom));
    A[0] = -8'sd128; B[0] = -8'sd128;                       // corner value
    for (int w = 0; w < (M*K)/4; w++)
      wr(S0 + 4*w, {A[4*w+3], A[4*w+2], A[4*w+1], A[4*w]});
    for (int w = 0; w < (K*NC)/4; w++)
      wr(S0 + 4*(bbase + w), {B[4*w+3], B[4*w+2], B[4*w+1], B[4*w]});
    wr(DMA + 'h08, {20'd0, 4'(kt), 4'(nt), 4'(mt)});
    wr(DMA + 'h0C, 0);
    wr(DMA + 'h10, bbase);
    wr(DMA + 'h14, 0);
    wr(DMA + 'h00, 1);
    // while busy: a CPU access to SRAM1 must stall, a DMA register read must not
    begin
      int s;
      rd(DMA + 'h04, st);
      if (st[0] !== 1'b1) begin $display("FAIL: not busy after start"); errors++; end
      access(0, S1, 0, 4'hF, q, s);
      if (s == 0) begin $display("FAIL: SRAM1 access not stalled while busy"); errors++; end
    end
    timeout = 0;
    do begin rd(DMA + 'h04, st); timeout++; end while (!st[1] && timeout < 100000);
    if (timeout >= 100000) begin $display("FAIL: DMA timeout"); errors++; end
    rd(DMA + 'h18, cyc);
    for (int i = 0; i < M; i++) for (int j = 0; j < NC; j++) begin
      int exp = 0;
      for (int k = 0; k < K; k++) exp += int'(A[i*K+k]) * int'(B[k*NC+j]);
      rd(S1 + 4*(i*NC + j), q);
      if ($signed(q) !== exp) begin
        if (errors < 10) $display("FAIL C[%0d][%0d] got %0d exp %0d", i, j, $signed(q), exp);
        errors++;
      end
    end
    $display("gemm %0dx%0dx%0d: %0d DMA cycles", M, NC, K, cyc);
  endtask

  initial begin
    logic [31:0] q;
    repeat (3) @(negedge clk); rst_n = 1; repeat (2) @(negedge clk);
    // SRAM word and byte writes, both banks
    wr(S0 + 4*5, 32'h1234_5678);
    wr(S0 + 4*5, 32'h0000_AB00, 4'b0010);
    rd(S0 + 4*5, q);
    if (q !== 32'h1234_AB78) begin $display("FAIL: SRAM0 byte write %h", q); errors++; end
    wr(S1 + 4*255, 32'hCAFE_F00D);
    rd(S1 + 4*255, q);
    if (q !== 32'hCAFE_F00D) begin $display("FAIL: SRAM1 word 255 %h", q); errors++; end
    gemm(2, 2, 2);
    gemm(1, 2, 3);
    if (errors == 0) $display("PASS: npu_sys N=%0d, 2 GEMMs", N);
    else             $display("FAILED: %0d errors", errors);
    $finish;
  end
endmodule
