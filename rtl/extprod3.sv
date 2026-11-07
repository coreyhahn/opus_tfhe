// External product over the RNS Q = 249857 * 188417 * 163841 (docs/PARAMS.md): signed gadget
// digits in, the three residues of O_0, O_1 out. Three extprod1 lanes run in lockstep.
// Digit d (|d| <= 2^22, 24-bit two's complement) -> d mod p: d = h 2^18 + l, l = d[17:0] unsigned,
// h = d[23:18] signed; r = l + (h 2^18 mod p), then at most two subtractions of p.
module extprod3 #(
  parameter int    RED    = ntt_pkg::RED_MONT,
  parameter int    T      = 8,
  parameter int    M      = 1,
  parameter string ROMDIR = ""          // holds twf_p<p>.hex and twi_p<p>.hex
) (
  input  logic                       clk,
  input  logic                       rst,
  input  logic                       op_we,
  input  logic [$clog2(2048/M)-1:0]  op_addr,
  input  logic [3*4*M*18-1:0]        op_wdata,     // residue i at [i*4*M*18 +: 4*M*18]
  output logic                       in_job_ready,
  input  logic                       in_job_start,
  input  logic                       in_valid,
  input  logic [M*24-1:0]            in_d0,
  input  logic [M*24-1:0]            in_d1,
  input  logic                       out_job_ready,
  output logic                       out_job_start,
  output logic                       out_valid,
  output logic [3*M*18-1:0]          out_data0,    // residue i at [i*M*18 +: M*18]
  output logic [3*M*18-1:0]          out_data1,
  output logic                       busy
);
  localparam int    PR [3] = '{249857, 188417, 163841};
  localparam string PS [3] = '{"249857", "188417", "163841"};

  typedef logic [63:0][17:0] tab_t;
  function automatic tab_t hi_tab(input int p);
    tab_t t;
    for (int c = 0; c < 64; c++) begin
      longint h;
      h = (c >= 32) ? longint'(c) - 64 : longint'(c);
      t[c] = 18'(((h << 18) % longint'(p) + longint'(p)) % longint'(p));
    end
    return t;
  endfunction

  logic [2:0] ijr, ojs, ov, bz;
  logic       v1, v2;
  always_ff @(posedge clk) begin
    v1 <= in_valid;
    v2 <= v1;
  end

  for (genvar i = 0; i < 3; i++) begin : g_res
    localparam tab_t HT = hi_tab(PR[i]);
    localparam logic [19:0] P20  = 20'(PR[i]);
    localparam logic [19:0] P2X  = 20'(2 * PR[i]);
    logic [M*18-1:0] r0, r1;
    for (genvar m = 0; m < M; m++) begin : g_d2r
      logic [19:0] s0, s1;
      always_ff @(posedge clk) begin
        s0 <= 20'(in_d0[m*24 +: 18]) + 20'(HT[in_d0[m*24+18 +: 6]]);
        s1 <= 20'(in_d1[m*24 +: 18]) + 20'(HT[in_d1[m*24+18 +: 6]]);
        r0[m*18 +: 18] <= 18'((s0 >= P2X) ? s0 - P2X : (s0 >= P20) ? s0 - P20 : s0);
        r1[m*18 +: 18] <= 18'((s1 >= P2X) ? s1 - P2X : (s1 >= P20) ? s1 - P20 : s1);
      end
    end
    extprod1 #(.P(PR[i]), .RED(RED), .T(T), .M(M),
               .ROM_FWD({ROMDIR, "/twf_p", PS[i], ".hex"}), .ROM_INV({ROMDIR, "/twi_p", PS[i], ".hex"})) u_xp (
      .clk(clk), .rst(rst), .op_we(op_we), .op_addr(op_addr), .op_wdata(op_wdata[i*4*M*18 +: 4*M*18]),
      .in_job_ready(ijr[i]), .in_job_start(in_job_start), .in_valid(v2), .in_data0(r0), .in_data1(r1),
      .out_job_ready(out_job_ready), .out_job_start(ojs[i]), .out_valid(ov[i]),
      .out_data0(out_data0[i*M*18 +: M*18]), .out_data1(out_data1[i*M*18 +: M*18]), .busy(bz[i]));
  end

  // the lanes are identical machines fed identically: they stay in lockstep
  assign in_job_ready  = &ijr;
  assign out_job_start = ojs[0];
  assign out_valid     = ov[0];
  assign busy          = |bz || v1 || v2;
  // synthesis translate_off
  always @(posedge clk) if (!rst && (ojs != {3{ojs[0]}} || ov != {3{ov[0]}}))
    $fatal(1, "extprod3: residue lanes out of lockstep");
  // synthesis translate_on
endmodule
