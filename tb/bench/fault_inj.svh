// Fault injection for tb_gemm (included under `define FAULT). One single-bit upset (SEU) in a flop:
// the value is forced flipped at the falling edge and released 10 ps later, so the flop keeps the wrong
// value until its next write. +FAULT=<id> +FCYC=<cycles after the start marker>.
//   0 none (control)
//   1 main core   if_stage pc_id_o bit 2            -> lockstep mismatch
//   2 shadow core if_stage pc_id_o bit 2            -> lockstep mismatch
//   3 main core   register file x10 bit 0 (ECC word) -> RF ECC error
//   4 lockstep    shadow_outputs_q bit 0            -> mismatch in the comparator input
//   5 npu_acc     PE[3][3] accumulator bit 4 (NPU_TOP, NPU GEMM) -> not covered by the lockstep
// RTL hierarchy names (Verilator/Xcelium RTL runs).
`ifdef NPU_TOP
`define FI_TOP dut.u_cpu.u_ibex_top
`else
`define FI_TOP dut.u_ibex_top
`endif
`define FI_CORE   `FI_TOP.u_ibex_core
`define FI_LS     `FI_TOP.gen_lockstep.u_ibex_lockstep
`define FI_SHADOW `FI_LS.u_shadow_core
`define FI_RF10   `FI_TOP.gen_regfile_ff.register_file_i.g_plain_rf.g_rf_flops[10].rf_reg_q

  int     fault_id  = 0;
  int     fault_dly = 2000;   // cycles after the start marker
  longint fault_cyc = -1;
  logic [38:0] fi_v;          // value before the flip
  initial begin
    void'($value$plusargs("FAULT=%d", fault_id));
    void'($value$plusargs("FCYC=%d", fault_dly));
    wait (fetch == 1);
    wait (mark[0] >= 0);
    fault_cyc = mark[0] + fault_dly;
    wait (cyc == fault_cyc);
    @(negedge clk);
    case (fault_id)
      1: begin fi_v = `FI_CORE.if_stage_i.pc_id_o;
               force `FI_CORE.if_stage_i.pc_id_o = fi_v[31:0] ^ 32'h4; #0.01; release `FI_CORE.if_stage_i.pc_id_o; end
      2: begin fi_v = `FI_SHADOW.if_stage_i.pc_id_o;
               force `FI_SHADOW.if_stage_i.pc_id_o = fi_v[31:0] ^ 32'h4; #0.01; release `FI_SHADOW.if_stage_i.pc_id_o; end
      3: begin fi_v = `FI_RF10;
               force `FI_RF10 = fi_v ^ 39'h1; #0.01; release `FI_RF10; end
      4: begin force `FI_LS.shadow_outputs_q.data_req = ~`FI_LS.shadow_outputs_q.data_req; #0.01;
               release `FI_LS.shadow_outputs_q.data_req; end
`ifdef NPU_TOP
      5: begin fi_v = dut.u_acc.u_array.g_row[3].g_col[3].u_pe.acc_o;
               force dut.u_acc.u_array.g_row[3].g_col[3].u_pe.acc_o = fi_v[31:0] ^ 32'h10; #0.01;
               release dut.u_acc.u_array.g_row[3].g_col[3].u_pe.acc_o; end
`endif
      default: ;
    endcase
    $display("FAULT %0d injected at cycle %0d (%0t)", fault_id, fault_cyc, $time);
  end

  // which alert source fired first after the fault (core-internal checks vs lockstep comparator/shadow)
  logic fi_src_done = 0;
  always @(posedge clk) if (!fi_src_done && fault_cyc >= 0 && cyc >= fault_cyc &&
                            (`FI_TOP.core_alert_major_internal === 1'b1 || `FI_TOP.lockstep_alert_major_internal === 1'b1)) begin
    fi_src_done = 1;
    $display("RESULT fault %0d alert source at cycle %0d: core_internal %b, lockstep %b (mismatch %b)", fault_id, cyc,
             `FI_TOP.core_alert_major_internal, `FI_TOP.lockstep_alert_major_internal, `FI_LS.outputs_mismatch);
  end
