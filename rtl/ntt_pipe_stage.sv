// One stage of rtl/ntt_pipe.sv: optional delay shuffle (time bit TK -> path bit 0), select
// register with the twiddle ROM read, then P/2 butterflies. See ntt_pipe.sv for the scheme.
module ntt_pipe_stage #(
  parameter int    P        = 249857,
  parameter int    RED      = ntt_pkg::RED_MONT,
  parameter int    DIR      = 0,
  parameter int    PLOG     = 4,
  parameter int    TK       = -1,         // shuffle time bit, -1 = none
  parameter int    C        = 0,          // butterfly pair path bit
  parameter string ROM_FILE = ""
) (
  input  logic                     clk,
  input  logic                     in_valid,
  input  logic                     in_sof,
  input  logic                     in_tag,
  input  logic [(1<<PLOG)*18-1:0]  in_data,
  output logic                     out_valid,
  output logic                     out_sof,
  output logic                     out_tag,
  output logic [(1<<PLOG)*18-1:0]  out_data
);
  localparam int PP = 1 << PLOG;
  localparam int FB = ntt_pkg::LOG_N - PLOG;         // frame-local time bits
  localparam int L  = (TK >= 0) ? (1 << TK) : 0;
  localparam int LB = ntt_pkg::bfly_lat(RED);
  localparam int OD = 1 + LB;                        // select register + butterfly

  function automatic int unit_path(input int u);    // the u-th path whose bit C is 0
    return ((u >> C) << (C + 1)) | (u & ((1 << C) - 1));
  endfunction

  // ---- frame-local time after the shuffle
  logic v1, sof1, tag1;
  logic [(PP/2)*18-1:0] rom [1 << FB];
  initial if (ROM_FILE != "") $readmemh(ROM_FILE, rom);

  logic [17:0] su [PP/2], sv [PP/2];      // selected pair (before the select register)
  logic [FB-1:0] tau;

  if (TK >= 0) begin : g_shf
    // valid and sof delayed L; data delay lines per path pair
    logic vd [L], sd [L], td [L];
    always_ff @(posedge clk) begin
      vd[0] <= in_valid;
      sd[0] <= in_sof;
      td[0] <= in_tag;
      for (int k = 1; k < L; k++) begin
        vd[k] <= vd[k-1];
        sd[k] <= sd[k-1];
        td[k] <= td[k-1];
      end
    end
    assign v1 = vd[L-1];
    assign sof1 = sd[L-1];
    assign tag1 = td[L-1];
    // tau as a register: sof1's next value is one step back in its delay line, so the twiddle
    // ROM address and the pair select (tau[TK], every pair) come straight from flip-flops
    logic sof1_nx;
    logic [FB-1:0] tau_q;
    assign sof1_nx = (L >= 2) ? sd[(L >= 2) ? L-2 : 0] : in_sof;
    always_ff @(posedge clk) tau_q <= sof1_nx ? '0 : tau_q + 1'b1;
    assign tau = tau_q;
    for (genvar u = 0; u < PP / 2; u++) begin : g_pair
      logic [17:0] a_d1 [L], b_d1 [L], b_d2 [L];
      always_ff @(posedge clk) begin
        a_d1[0] <= in_data[(2*u)*18 +: 18];
        b_d1[0] <= in_data[(2*u+1)*18 +: 18];
        b_d2[0] <= b_d1[L-1];
        for (int k = 1; k < L; k++) begin
          a_d1[k] <= a_d1[k-1];
          b_d1[k] <= b_d1[k-1];
          b_d2[k] <= b_d2[k-1];
        end
      end
      // even-path pairs while time bit TK of tau is 0, odd-path pairs while it is 1
      assign su[u] = tau[TK] ? b_d2[L-1] : a_d1[L-1];
      assign sv[u] = tau[TK] ? b_d1[L-1] : in_data[(2*u)*18 +: 18];
    end
  end else begin : g_direct
    assign v1 = in_valid;
    assign sof1 = in_sof;
    assign tag1 = in_tag;
    logic [FB-1:0] tau_r;
    assign tau = sof1 ? '0 : tau_r;
    always_ff @(posedge clk) tau_r <= tau + 1'b1;
    for (genvar u = 0; u < PP / 2; u++) begin : g_pair
      assign su[u] = in_data[unit_path(u)*18 +: 18];
      assign sv[u] = in_data[(unit_path(u) | (1 << C))*18 +: 18];
    end
  end


  // ---- select register (pair + twiddle), then the butterflies
  logic [17:0] ru [PP/2], rv [PP/2];
  logic [(PP/2)*18-1:0] rw;
  always_ff @(posedge clk) begin
    for (int u = 0; u < PP / 2; u++) begin
      ru[u] <= su[u];
      rv[u] <= sv[u];
    end
    rw <= rom[tau];
  end

  for (genvar u = 0; u < PP / 2; u++) begin : g_bf
    logic [17:0] ba, bb;
    bfly #(.P(P), .RED(RED), .DIR(DIR)) u_bf (
      .clk(clk), .u(ru[u]), .v(rv[u]), .wc(rw[u*18 +: 18]), .a(ba), .b(bb));
    assign out_data[unit_path(u)*18 +: 18]              = ba;
    assign out_data[(unit_path(u) | (1 << C))*18 +: 18] = bb;
  end

  logic ov [OD], os [OD], ot [OD];
  always_ff @(posedge clk) begin
    ov[0] <= v1;
    os[0] <= sof1;
    ot[0] <= tag1;
    for (int k = 1; k < OD; k++) begin
      ov[k] <= ov[k-1];
      os[k] <= os[k-1];
      ot[k] <= ot[k-1];
    end
  end
  assign out_valid = ov[OD-1];
  assign out_sof   = os[OD-1];
  assign out_tag   = ot[OD-1];
endmodule
