// Memory-mapped INT8 matrix-multiply accelerator: C = A x B (N x N), 32-bit accumulators.
// Bus: Ibex-style req/gnt/rvalid. gnt is combinational (= req); rvalid one cycle later.
//
// Register map (byte offsets inside the 4 KB window):
//   0x000 CTRL   W : bit0 = start (self-clearing; ignored while busy)
//   0x004 STATUS R : bit0 = busy, bit1 = done (cleared by the next start)
//   0x008 INFO   R : [7:0] = N, [15:8] = AW, [23:16] = ACCW
//   0x100 A      RW: A[i][k] = byte (i*N+k), little-endian packed, row-major (writes ignored while busy)
//   0x200 B      RW: B[k][j] = byte (k*N+j), same packing (writes ignored while busy)
//   0x300 C      R : word (i*N+j) = C[i][j], signed 32-bit
module npu_acc #(
  parameter int N    = 8,
  parameter int AW   = 8,
  parameter int ACCW = 32
) (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        req_i,
  input  logic        we_i,
  input  logic [3:0]  be_i,
  input  logic [31:0] addr_i,
  input  logic [31:0] wdata_i,
  output logic        gnt_o,
  output logic        rvalid_o,
  output logic [31:0] rdata_o
);
  localparam int NBYTES = N*N;                 // AW must be 8 for the byte-packed map
  localparam int NWORDS = (NBYTES + 3) / 4;
  localparam int CW     = $clog2(3*N);

  typedef enum logic [1:0] {S_IDLE, S_CLR, S_RUN, S_DONE} state_e;
  state_e state_q;
  logic [CW-1:0] cnt_q;

  logic [NWORDS*32-1:0] a_q, b_q;
  logic [N*N*ACCW-1:0]  c_w;
  logic [N*AW-1:0]      a_edge, b_edge;

  wire busy = (state_q == S_CLR) || (state_q == S_RUN);

  // ---------------- bus ----------------
  assign gnt_o = req_i;
  wire        acc_req = req_i;
  wire [3:0]  sel     = addr_i[11:8];
  wire [5:0]  idx     = addr_i[7:2];

  logic start;
  always_comb begin
    start = 1'b0;
    if (acc_req && we_i && sel == 4'h0 && idx == 6'd0 && be_i[0] && wdata_i[0] && !busy)
      start = 1'b1;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      a_q <= '0;
      b_q <= '0;
    end else if (acc_req && we_i && !busy) begin
      for (int w = 0; w < NWORDS; w++) begin
        for (int b = 0; b < 4; b++) begin
          if (be_i[b] && idx == 6'(w)) begin
            if (sel == 4'h1) a_q[32*w + 8*b +: 8] <= wdata_i[8*b +: 8];
            if (sel == 4'h2) b_q[32*w + 8*b +: 8] <= wdata_i[8*b +: 8];
          end
        end
      end
    end
  end

  logic [31:0] rdata_d;
  always_comb begin
    rdata_d = '0;
    unique case (sel)
      4'h0: begin
        if (idx == 6'd1) rdata_d = {30'd0, (state_q == S_DONE), busy};
        if (idx == 6'd2) rdata_d = {8'd0, 8'(ACCW), 8'(AW), 8'(N)};
      end
      4'h1: for (int w = 0; w < NWORDS; w++) if (idx == 6'(w)) rdata_d = a_q[32*w +: 32];
      4'h2: for (int w = 0; w < NWORDS; w++) if (idx == 6'(w)) rdata_d = b_q[32*w +: 32];
      4'h3: for (int e = 0; e < N*N; e++)    if (idx == 6'(e)) rdata_d = c_w[ACCW*e +: ACCW];
      default: rdata_d = '0;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rvalid_o <= 1'b0;
      rdata_o  <= '0;
    end else begin
      rvalid_o <= req_i;
      if (req_i && !we_i) rdata_o <= rdata_d;
    end
  end

  // ---------------- control FSM ----------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= S_IDLE;
      cnt_q   <= '0;
    end else begin
      unique case (state_q)
        S_IDLE, S_DONE: if (start) state_q <= S_CLR;
        S_CLR:          begin state_q <= S_RUN; cnt_q <= '0; end
        S_RUN:          begin
          if (cnt_q == CW'(3*N-3)) state_q <= S_DONE;
          else                     cnt_q   <= cnt_q + 1'b1;
        end
        default: state_q <= S_IDLE;
      endcase
    end
  end

  // ---------------- skewed edge feed ----------------
  // PE(i,j) sees A[i][k] and B[k][j] at cycle t = i + j + k.
  always_comb begin
    a_edge = '0;
    b_edge = '0;
    for (int i = 0; i < N; i++) begin
      automatic int k = int'(cnt_q) - i;
      if (state_q == S_RUN && k >= 0 && k < N)
        a_edge[AW*i +: AW] = a_q[8*(i*N + k) +: 8];
    end
    for (int j = 0; j < N; j++) begin
      automatic int k = int'(cnt_q) - j;
      if (state_q == S_RUN && k >= 0 && k < N)
        b_edge[AW*j +: AW] = b_q[8*(k*N + j) +: 8];
    end
  end

  sysarr #(.N(N), .AW(AW), .ACCW(ACCW)) u_array (
    .clk_i, .rst_ni,
    .clear_i  (state_q == S_CLR),
    .en_i     (state_q == S_RUN),
    .a_edge_i (a_edge),
    .b_edge_i (b_edge),
    .c_o      (c_w)
  );
endmodule
