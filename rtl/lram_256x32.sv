// 1 KB single-port latch SRAM (256 words x 32 bits, byte writes), built from standard cells and hardened as a macro.
// The library has no SRAM and no ICG cell: one dlatch per bit, one latch + AND clock gate per word and byte lane.
//
// Timing (like a synchronous SRAM with registered inputs):
//   cycle t  : ce_i, we_i, be_i, addr_i, wdata_i set up to the rising edge that ends t (captured in flops)
//   cycle t+1: write: the byte select is decoded from the input flops (full cycle)
//              read : rdata_o = word[addr_q], combinational from the latch array, valid in t+1, held until the next access
//   cycle t+2: write: the selected byte latches are open during the HIGH half of t+2 and close at the falling edge.
//              A read of the same word accepted in t+1 sees the new data through the open latch in t+2.
//
// Write clock gate per word/byte (standard AND-type ICG built by hand):
//   en_l = latch(en_d) while clk is LOW (en_d settles from the input flops, glitches filtered)
//   gclk = clk & en_l      -> data latches open while clk is HIGH; en_l is frozen then, so gclk has no glitch.
// Why not the low phase: rdata_o is due at 325 ps, and a latch opening at the falling edge launches at 375 ps, so the
// latch -> read mux -> rdata_o path could never meet timing. High phase launches at 0, with the same budget as addr_q.
// wdata_qq is launched by the rising edge that opens the latches and closes half a cycle before it changes, so the
// array has no hold race.
module lram_256x32 (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        ce_i,
  input  logic        we_i,
  input  logic [3:0]  be_i,
  input  logic [7:0]  addr_i,
  input  logic [31:0] wdata_i,
  output logic [31:0] rdata_o
);
  localparam int WORDS = 256;

  logic        we_q;
  logic [3:0]  be_q;
  logic [7:0]  addr_q;
  logic [31:0] wdata_q, wdata_qq;            // qq: stable during the high-phase write pulse of t+2

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) we_q <= 1'b0;                  // no stray write after reset; the array itself has no reset
    else         we_q <= ce_i & we_i;
  end
  always_ff @(posedge clk_i) begin
    if (ce_i) begin
      addr_q <= addr_i;
      be_q   <= be_i;
      if (we_i) wdata_q <= wdata_i;
    end
    wdata_qq <= wdata_q;
  end

  logic [WORDS-1:0][31:0] word;

  for (genvar w = 0; w < WORDS; w++) begin : g_word
    wire sel = we_q && (addr_q == 8'(w));
    for (genvar b = 0; b < 4; b++) begin : g_byte
      logic en_l, gclk;
      logic [7:0] q;
      always_latch if (!clk_i) en_l = sel & be_q[b];
      assign gclk = clk_i & en_l;
      always_latch if (gclk) q = wdata_qq[8*b +: 8];
      assign word[w][8*b +: 8] = q;
    end
  end

  assign rdata_o = word[addr_q];
endmodule
