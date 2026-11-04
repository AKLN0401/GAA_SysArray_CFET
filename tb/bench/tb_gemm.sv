// CPU-vs-NPU benchmark: C (16x16 int32) = A (16x16 int8) x B (16x16 int8), programs from scripts/gen_gemm_prog.py.
// Same bus model for both tops: instruction ROM and 16 KB external data memory at 0x2000_0000, gnt = req,
// rvalid one cycle later. RTL (Verilator) or gate level (Xcelium, + SDF).
// Defines:
//   NPU_TOP            DUT ibex_npu_top (else ibex_cfet_top)
//   PROG               instruction hex (default "prog_sw.hex"), DATA data hex (default "data.hex")
//   CLK_PERIOD         ns, default 0.75; IN_DLY_NS input delay after the edge (default 10% of the period);
//                      RST_DLY_NS reset/fetch release after the edge (default IN_DLY_NS);
//   RST_NOCLK          release reset and fetch_enable while the clock is stopped
//   SDF_DIR, SDF_VIEW, SDF_CORNER   SDF annotation (gate level)
//   SAIF               Xcelium: toggle counts from the start marker to the end marker -> SAIF (file name)
// Markers: a store to 0x2000_2000 + 4*id records the cycle (0 start, 1 end, 2 copy-in done, 3 DMA done,
// 4 = value of the DMA CYCLES register). At the end marker C is checked against A x B.
`timescale 1ns/1ps
`ifndef CLK_PERIOD
`define CLK_PERIOD 0.75
`endif
`ifndef PROG
`define PROG "prog_sw.hex"
`endif
`ifndef DATA
`define DATA "data.hex"
`endif
`ifndef SDF_CORNER
`define SDF_CORNER "MAXIMUM"
`endif
module tb_gemm;
  localparam real T = `CLK_PERIOD;
`ifdef IN_DLY_NS
  localparam real IN_DLY = `IN_DLY_NS;
`else
  localparam real IN_DLY = 0.1 * T;
`endif
`ifdef RST_DLY_NS
  localparam real RST_DLY = `RST_DLY_NS;  // reset/fetch release after the edge (macro clock latency at SS)
`else
  localparam real RST_DLY = IN_DLY;
`endif

  logic clk = 0, rst_n = 0, fetch = 0;
  logic clk_en = 1;
  always #(T/2) if (clk_en) clk = ~clk; else clk = 1'b0;

  logic        i_req, i_gnt, i_rvalid = 0, i_err = 0;
  logic [31:0] i_addr, i_rdata = 0;
  logic        d_req, d_gnt, d_rvalid = 0, d_we, d_err = 0;
  logic [3:0]  d_be;
  logic [31:0] d_addr, d_wdata, d_rdata = 0;
  logic        sleep, a_minor, a_int, a_bus;

  assign #(IN_DLY) i_gnt = i_req;
  assign #(IN_DLY) d_gnt = d_req;

`ifdef NPU_TOP
  ibex_npu_top dut (.clk_i(clk), .rst_ni(rst_n), .fetch_enable_i(fetch), .boot_addr_i(32'h0),
    .instr_req_o(i_req), .instr_gnt_i(i_gnt), .instr_rvalid_i(i_rvalid), .instr_addr_o(i_addr),
    .instr_rdata_i(i_rdata), .instr_err_i(i_err),
    .mem_req_o(d_req), .mem_gnt_i(d_gnt), .mem_rvalid_i(d_rvalid), .mem_we_o(d_we), .mem_be_o(d_be),
    .mem_addr_o(d_addr), .mem_wdata_o(d_wdata), .mem_rdata_i(d_rdata), .mem_err_i(d_err),
`else
  ibex_cfet_top dut (.clk_i(clk), .rst_ni(rst_n), .fetch_enable_i(fetch), .boot_addr_i(32'h0),
    .instr_req_o(i_req), .instr_gnt_i(i_gnt), .instr_rvalid_i(i_rvalid), .instr_addr_o(i_addr),
    .instr_rdata_i(i_rdata), .instr_err_i(i_err),
    .data_req_o(d_req), .data_gnt_i(d_gnt), .data_rvalid_i(d_rvalid), .data_we_o(d_we), .data_be_o(d_be),
    .data_addr_o(d_addr), .data_wdata_o(d_wdata), .data_rdata_i(d_rdata), .data_err_i(d_err),
`endif
    .irq_software_i(1'b0), .irq_timer_i(1'b0), .irq_external_i(1'b0), .irq_fast_i(15'h0), .irq_nm_i(1'b0),
    .debug_req_i(1'b0), .core_sleep_o(sleep), .alert_minor_o(a_minor), .alert_major_internal_o(a_int),
    .alert_major_bus_o(a_bus));

`ifdef SDF_VIEW
  initial begin
`ifdef NPU_TOP
    $sdf_annotate({`SDF_DIR, "/ibex_npu_top/ibex_npu_top_", `SDF_VIEW, ".sdf"}, dut, , "sdf_top.log", `SDF_CORNER);
    $sdf_annotate({`SDF_DIR, "/npu_acc_m3stub/npu_acc_", `SDF_VIEW, ".sdf"}, dut.u_acc, , "sdf_acc.log", `SDF_CORNER);
    $sdf_annotate({`SDF_DIR, "/lram_256x32_m3stub/lram_256x32_", `SDF_VIEW, ".sdf"}, dut.u_sram0, , "sdf_s0.log", `SDF_CORNER);
    $sdf_annotate({`SDF_DIR, "/lram_256x32_m3stub/lram_256x32_", `SDF_VIEW, ".sdf"}, dut.u_sram1, , "sdf_s1.log", `SDF_CORNER);
`else
    $sdf_annotate({`SDF_DIR, "/ibex_cfet_top/ibex_cfet_top_", `SDF_VIEW, ".sdf"}, dut, , "sdf_top.log", `SDF_CORNER);
`endif
  end
`endif

  logic [31:0] rom [0:1023];
  logic [31:0] mem [0:4095];
  string prog = `PROG;
  initial begin
    void'($value$plusargs("PROG=%s", prog));   // runtime override: +PROG=prog_npu.hex
    $readmemh(prog, rom);
    $readmemh(`DATA, mem);
  end

  wire d_ext = (d_addr[31:14] == 18'h0_8000);   // 0x2000_0000 .. 0x2000_3FFF

  longint cyc = 0;
  longint mark [0:4];
  int     seen_end = 0, errors = 0;
  longint alert_cyc = -1;
  always @(posedge clk) if (rst_n) cyc <= cyc + 1;

  always @(posedge clk) begin
    i_rvalid <= #(IN_DLY) (i_req === 1'b1);
    i_rdata  <= #(IN_DLY) (i_req === 1'b1) ? rom[i_addr[11:2]] : 32'h0;
    d_rvalid <= #(IN_DLY) (d_req === 1'b1);
    d_rdata  <= #(IN_DLY) (d_req === 1'b1 && d_we !== 1'b1 && d_ext) ? mem[d_addr[13:2]] : 32'h0;
    if (rst_n && d_req === 1'b1 && d_we === 1'b1 && d_ext) begin
      for (int b = 0; b < 4; b++) if (d_be[b]) mem[d_addr[13:2]][8*b +: 8] <= d_wdata[8*b +: 8];
      if (d_addr[13:2] >= 12'h800 && d_addr[13:2] <= 12'h804) begin   // markers 0x2000_2000 + 4*id
        if (d_addr[4:2] == 3'd4) mark[4] = longint'(d_wdata);
        else                     mark[d_addr[4:2]] = cyc;
        if (d_addr[4:2] == 3'd1) seen_end = 1;
      end
    end
    if (fetch && (a_int !== 1'b0 || a_bus !== 1'b0)) begin
      if (alert_cyc < 0) alert_cyc = cyc;
`ifndef FAULT
      if (errors < 5) $display("FAIL: major alert %b %b at %0t", a_int, a_bus, $time);
      errors++;
`endif
    end
  end

`ifdef SAIF
  // run_saif.tcl starts dumpsaif at the first $stop (start marker) and ends it at the second (end marker)
  logic saif_on = 0;
  always @(posedge clk) begin
    if (!saif_on && mark[0] >= 0) begin saif_on = 1; $stop; end
  end
`endif

`ifdef FAULT
`include "fault_inj.svh"
`endif

  function automatic int sbyte(input int addr);
    logic [7:0] v = mem[addr >> 2][8*(addr & 3) +: 8];
    return int'($signed(v));
  endfunction

  initial begin
    for (int n = 0; n < 5; n++) mark[n] = -1;
    #0 $display("tb_gemm: period %0.3f ns, prog %s", T, prog);
`ifdef RST_NOCLK
    // reset released with the clock stopped (low): no recovery/removal race at slow corners
    repeat (5) @(posedge clk); @(negedge clk); clk_en = 0; #(4*T); rst_n = 1; #(4*T); clk_en = 1;
    repeat (5) @(posedge clk); @(negedge clk); clk_en = 0; #(4*T); fetch = 1; #(4*T); clk_en = 1;
`else
    repeat (5) @(posedge clk); #(RST_DLY); rst_n = 1;
`endif
`ifndef RST_NOCLK
    repeat (5) @(posedge clk); #(RST_DLY); fetch = 1;
`endif
    fork
      wait (seen_end == 1);
      repeat (200000) @(posedge clk);
    join_any
`ifdef SAIF
    $stop;
`endif
    repeat (5) @(posedge clk);
    if (!seen_end) begin $display("FAIL: timeout"); errors++; end
    else begin
      for (int i = 0; i < 16; i++)
        for (int j = 0; j < 16; j++) begin
          int s;
          s = 0;
          for (int k = 0; k < 16; k++) s += sbyte(i*16 + k) * sbyte(32'h100 + k*16 + j);
          if (mem[(32'h1000 >> 2) + i*16 + j] !== 32'(s)) begin
            if (errors < 10) $display("FAIL: C[%0d][%0d] = %0d, expected %0d", i, j,
                                      $signed(mem[(32'h1000 >> 2) + i*16 + j]), s);
            errors++;
          end
        end
    end
    $display("RESULT cycles start->end %0d", mark[1] - mark[0]);
    if (mark[2] >= 0) $display("RESULT cycles copy-in %0d, dma (cpu poll) %0d, copy-out %0d, DMA CYCLES reg %0d",
                               mark[2] - mark[0], mark[3] - mark[2], mark[1] - mark[3], mark[4]);
    $display("RESULT time start->end %0.1f ns at %0.3f ns", real'(mark[1] - mark[0]) * T, T);
`ifdef FAULT
    if (alert_cyc >= 0) $display("RESULT fault %0d at cycle %0d: alert_major at cycle %0d (latency %0d), C errors %0d",
                                 fault_id, fault_cyc, alert_cyc, alert_cyc - fault_cyc, errors);
    else                $display("RESULT fault %0d at cycle %0d: NO alert, C errors %0d", fault_id, fault_cyc, errors);
`endif
    if (errors == 0) $display("PASS: tb_gemm 16x16x16");
    else             $display("FAILED: %0d errors", errors);
    $finish;
  end
endmodule
