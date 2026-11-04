// Gate-level testbench for npu_acc (post-P&R netlist + SDF, or the synthesis netlist with zero delay).
// Same checks as tb_npu_acc.sv: INFO register, two random runs, one corner run (-128 * -128), write-while-busy.
// Clocking follows constraints/npu_acc.sdc: inputs change IN_DLY (30%) after the rising edge, outputs are
// sampled OUT_SMP (70%) after the edge, i.e. inside the SDC output budget.
//
// Defines (all optional):
//   CLK_PERIOD  clock period in ns (default 0.75)
//   SDF_FILE    SDF to annotate onto dut, e.g. +define+SDF_FILE=\"pnr/npu_acc/npu_acc_ssgm40.sdf\"
//   SDF_CORNER  "MAXIMUM" (setup views, default) or "MINIMUM" (hold views)
//   DUMP        write tb_npu_acc_gls.vcd
`timescale 1ns/1ps
`ifndef CLK_PERIOD
`define CLK_PERIOD 0.75
`endif
`ifndef SDF_CORNER
`define SDF_CORNER "MAXIMUM"
`endif
module tb_npu_acc_gls;
  localparam int  N       = 8;                     // the netlist was synthesized with the default N
  localparam real T       = `CLK_PERIOD;
  localparam real IN_DLY  = 0.3 * T;
  localparam real OUT_SMP = 0.7 * T;

  logic clk = 0, rst_n = 0;
  logic req = 0, we = 0; logic [3:0] be = 4'hF; logic [31:0] addr = 0, wdata = 0;
  logic gnt, rvalid; logic [31:0] rdata;
  always #(T/2) clk = ~clk;

  // gate netlist: no parameters
  npu_acc dut (.clk_i(clk), .rst_ni(rst_n), .req_i(req), .we_i(we), .be_i(be),
               .addr_i(addr), .wdata_i(wdata), .gnt_o(gnt), .rvalid_o(rvalid), .rdata_o(rdata));

`ifdef SDF_FILE
  initial $sdf_annotate(`SDF_FILE, dut, , "sdf_annotate.log", `SDF_CORNER);
`endif
`ifdef DUMP
  initial begin $dumpfile("tb_npu_acc_gls.vcd"); $dumpvars(0, tb_npu_acc_gls); end
`endif

  int errors = 0;
  logic signed [7:0] A [N][N], B [N][N];

  task automatic wr(input logic [31:0] a, input logic [31:0] d, input logic [3:0] b = 4'hF);
    @(posedge clk); #(IN_DLY); req = 1; we = 1; addr = a; wdata = d; be = b;
    @(posedge clk); #(IN_DLY); req = 0; we = 0;
  endtask
  task automatic rd(input logic [31:0] a, output logic [31:0] d);
    @(posedge clk); #(IN_DLY); req = 1; we = 0; addr = a;
    @(posedge clk); #(IN_DLY); req = 0;
    #(OUT_SMP - IN_DLY);                            // rvalid/rdata launched by the edge above
    if (rvalid !== 1'b1) begin $display("FAIL: rvalid missing at %0t", $time); errors++; end
    d = rdata;
  endtask

  task automatic load_and_run(input bit corner);
    logic [31:0] w, st; int timeout;
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
    wr(32'h100, 32'hDEADBEEF);                // write while busy must be ignored
    timeout = 0;
    do begin rd(32'h004, st); timeout++; end while (st[1] !== 1'b1 && timeout < 100);
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

  // gnt_o = req_i is a combinational feedthrough
  always @(posedge clk) if (rst_n && gnt !== req) begin
    $display("FAIL: gnt %b != req %b at %0t", gnt, req, $time); errors++;
  end

  initial begin
    logic [31:0] info;
    $display("tb_npu_acc_gls: period %0.3f ns%s", T,
`ifdef SDF_FILE
             ", SDF annotated"
`else
             ", no SDF (zero delay)"
`endif
             );
    repeat (3) @(posedge clk); #(IN_DLY); rst_n = 1; repeat (2) @(posedge clk);
    rd(32'h008, info);
    if (info[7:0] !== N || info[15:8] !== 8 || info[23:16] !== 32) begin
      $display("FAIL INFO %h", info); errors++;
    end
    load_and_run(0);
    load_and_run(0);
    load_and_run(1);
    if (errors == 0) $display("PASS: npu_acc gate-level N=%0d, 3 runs", N);
    else             $display("FAILED: %0d errors", errors);
    $finish;
  end
endmodule
