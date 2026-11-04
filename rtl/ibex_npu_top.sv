// Ibex (maxperf-pmp-bmfull) + memory-mapped INT8 systolic accelerator + 2 x 1 KB latch SRAM + tiled-GEMM DMA.
// Data accesses inside the 16 KB window at ACC_BASE go to npu_dma (npu_acc 0x0000, SRAM0 0x1000, SRAM1 0x2000,
// DMA registers 0x3000; see npu_dma.sv); everything else goes to the external memory port (mem_*).
// Instruction fetch is unchanged (external). Hard macros: u_acc (npu_acc), u_sram0, u_sram1 (lram_256x32).
module ibex_npu_top #(
  parameter logic [31:0] ACC_BASE = 32'h1000_0000,
  parameter int          N        = 8
) (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        fetch_enable_i,
  input  logic [31:0] boot_addr_i,

  // Instruction fetch bus
  output logic        instr_req_o,
  input  logic        instr_gnt_i,
  input  logic        instr_rvalid_i,
  output logic [31:0] instr_addr_o,
  input  logic [31:0] instr_rdata_i,
  input  logic        instr_err_i,

  // External data memory bus (accelerator window excluded)
  output logic        mem_req_o,
  input  logic        mem_gnt_i,
  input  logic        mem_rvalid_i,
  output logic        mem_we_o,
  output logic [3:0]  mem_be_o,
  output logic [31:0] mem_addr_o,
  output logic [31:0] mem_wdata_o,
  input  logic [31:0] mem_rdata_i,
  input  logic        mem_err_i,

  // Interrupts / debug
  input  logic        irq_software_i,
  input  logic        irq_timer_i,
  input  logic        irq_external_i,
  input  logic [14:0] irq_fast_i,
  input  logic        irq_nm_i,
  input  logic        debug_req_i,

  output logic        core_sleep_o,
  output logic        alert_minor_o,
  output logic        alert_major_internal_o,
  output logic        alert_major_bus_o
);
  logic        d_req, d_gnt, d_rvalid, d_we, d_err;
  logic [3:0]  d_be;
  logic [31:0] d_addr, d_wdata, d_rdata;

  ibex_cfet_top u_cpu (
    .clk_i, .rst_ni, .fetch_enable_i, .boot_addr_i,
    .instr_req_o, .instr_gnt_i, .instr_rvalid_i, .instr_addr_o, .instr_rdata_i, .instr_err_i,
    .data_req_o (d_req),  .data_gnt_i (d_gnt), .data_rvalid_i (d_rvalid),
    .data_we_o  (d_we),   .data_be_o  (d_be),  .data_addr_o   (d_addr),
    .data_wdata_o (d_wdata), .data_rdata_i (d_rdata), .data_err_i (d_err),
    .irq_software_i, .irq_timer_i, .irq_external_i, .irq_fast_i, .irq_nm_i, .debug_req_i,
    .core_sleep_o, .alert_minor_o, .alert_major_internal_o, .alert_major_bus_o
  );

  // ---- address decode ----
  wire sel_loc = (d_addr[31:14] == ACC_BASE[31:14]);

  logic        loc_gnt, loc_rvalid;
  logic [31:0] loc_rdata;

  assign mem_req_o   = d_req & ~sel_loc;
  assign mem_we_o    = d_we;
  assign mem_be_o    = d_be;
  assign mem_addr_o  = d_addr;
  assign mem_wdata_o = d_wdata;

  logic        acc_req, acc_we, acc_gnt, acc_rvalid;
  logic [3:0]  acc_be;
  logic [31:0] acc_addr, acc_wdata, acc_rdata;
  logic        s0_ce, s0_we, s1_ce, s1_we;
  logic [3:0]  s0_be, s1_be;
  logic [7:0]  s0_addr, s1_addr;
  logic [31:0] s0_wdata, s0_rdata, s1_wdata, s1_rdata;

  npu_dma #(.N(N)) u_dma (
    .clk_i, .rst_ni,
    .s_req_i (d_req & sel_loc), .s_gnt_o (loc_gnt), .s_rvalid_o (loc_rvalid),
    .s_we_i (d_we), .s_be_i (d_be), .s_addr_i (d_addr[13:0]), .s_wdata_i (d_wdata), .s_rdata_o (loc_rdata),
    .acc_req_o (acc_req), .acc_we_o (acc_we), .acc_be_o (acc_be), .acc_addr_o (acc_addr), .acc_wdata_o (acc_wdata),
    .acc_gnt_i (acc_gnt), .acc_rvalid_i (acc_rvalid), .acc_rdata_i (acc_rdata),
    .sram0_ce_o (s0_ce), .sram0_we_o (s0_we), .sram0_be_o (s0_be), .sram0_addr_o (s0_addr),
    .sram0_wdata_o (s0_wdata), .sram0_rdata_i (s0_rdata),
    .sram1_ce_o (s1_ce), .sram1_we_o (s1_we), .sram1_be_o (s1_be), .sram1_addr_o (s1_addr),
    .sram1_wdata_o (s1_wdata), .sram1_rdata_i (s1_rdata)
  );

  npu_acc #(.N(N)) u_acc (
    .clk_i, .rst_ni,
    .req_i   (acc_req),
    .we_i    (acc_we),
    .be_i    (acc_be),
    .addr_i  (acc_addr),
    .wdata_i (acc_wdata),
    .gnt_o   (acc_gnt),
    .rvalid_o(acc_rvalid),
    .rdata_o (acc_rdata)
  );

  lram_256x32 u_sram0 (
    .clk_i, .rst_ni, .ce_i (s0_ce), .we_i (s0_we), .be_i (s0_be), .addr_i (s0_addr),
    .wdata_i (s0_wdata), .rdata_o (s0_rdata)
  );
  lram_256x32 u_sram1 (
    .clk_i, .rst_ni, .ce_i (s1_ce), .we_i (s1_we), .be_i (s1_be), .addr_i (s1_addr),
    .wdata_i (s1_wdata), .rdata_o (s1_rdata)
  );

  // Ibex's LSU has one outstanding access, so response sources never overlap.
  assign d_gnt    = sel_loc ? loc_gnt : mem_gnt_i;
  assign d_rvalid = loc_rvalid | mem_rvalid_i;
  assign d_rdata  = loc_rvalid ? loc_rdata : mem_rdata_i;
  assign d_err    = mem_err_i;
endmodule
