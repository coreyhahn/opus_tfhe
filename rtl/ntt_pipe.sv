// Streaming (feedforward) negacyclic NTT for one 18-bit prime: N = 2048, P = 2^PLOG coefficients
// per cycle, one polynomial per frame of N/P consecutive valid cycles. Frames may be separated by
// gaps of any length. Bit-exact target and data layout: ref/tfhe_model/src/ntt_pipe.rs.
//   DIR = 0 forward  : block-per-path layout in, forward-output layout out
//   DIR = 1 inverse  : forward-output layout in, block-per-path layout out (unscaled, x N)
// Stage i pairs positions differing in its span bit. If that bit is a path bit c, its P/2
// butterflies pair paths differing in bit c. If it is time bit t, a shuffle first moves it to path
// bit 0: on each path pair (2u, 2u+1) the even path is delayed L = 2^t and the odd path L and 2L,
// and the butterfly takes (even(t-L), even(t)) in one half of every 2L block and (odd(t-2L),
// odd(t-L)) in the other. Butterflies are busy every cycle. Twiddles: ROM_PFX + "_s<i>.hex",
// N/P lines of the P/2 units' stored constants, indexed by frame-local time after the shuffle.
module ntt_pipe #(
  parameter int    P       = 249857,
  parameter int    RED     = ntt_pkg::RED_MONT,
  parameter int    DIR     = 0,
  parameter int    PLOG    = 4,
  parameter string ROM_PFX = ""
) (
  input  logic                     clk,
  input  logic                     in_valid,
  input  logic                     in_sof,
  input  logic                     in_tag,      // any per-frame bit; emerges aligned with out_sof
  input  logic [(1<<PLOG)*18-1:0]  in_data,
  output logic                     out_valid,
  output logic                     out_sof,
  output logic                     out_tag,
  output logic [(1<<PLOG)*18-1:0]  out_data
);
  localparam int    NB = ntt_pkg::LOG_N;
  localparam string SFX [11] = '{"_s0.hex", "_s1.hex", "_s2.hex", "_s3.hex", "_s4.hex", "_s5.hex",
                                 "_s6.hex", "_s7.hex", "_s8.hex", "_s9.hex", "_s10.hex"};

  // stage plan, closed form (ntt_pipe.rs closed_form_stage, checked against the model's layout)
  function automatic int shuffle_bit(input int i);   // -1: no shuffle
    if (DIR == 0) return (i < PLOG) ? -1 : NB - 1 - i;
    return (i == 0 || i > NB - PLOG) ? -1 : i - 1;
  endfunction
  function automatic int pair_bit(input int i);
    if (DIR == 0) return (i < PLOG) ? PLOG - 1 - i : 0;
    return (i <= NB - PLOG) ? 0 : i - (NB - PLOG);
  endfunction

  logic                     v   [NB+1];
  logic                     sof [NB+1];
  logic                     tag [NB+1];
  logic [(1<<PLOG)*18-1:0]  d   [NB+1];
  assign v[0]   = in_valid;
  assign sof[0] = in_sof;
  assign tag[0] = in_tag;
  assign d[0]   = in_data;

  for (genvar i = 0; i < NB; i++) begin : g_st
    ntt_pipe_stage #(.P(P), .RED(RED), .DIR(DIR), .PLOG(PLOG), .TK(shuffle_bit(i)), .C(pair_bit(i)),
                     .ROM_FILE({ROM_PFX, SFX[i]})) u_st (
      .clk(clk), .in_valid(v[i]), .in_sof(sof[i]), .in_tag(tag[i]), .in_data(d[i]),
      .out_valid(v[i+1]), .out_sof(sof[i+1]), .out_tag(tag[i+1]), .out_data(d[i+1]));
  end
  assign out_valid = v[NB];
  assign out_sof   = sof[NB];
  assign out_tag   = tag[NB];
  assign out_data  = d[NB];
endmodule
