// Modular butterfly, latency ntt_pkg::bfly_lat(RED) for both directions.
//   DIR = 0 (forward, Cooley-Tukey): a = u + w v,   b = u - w v
//   DIR = 1 (inverse, Gentleman-Sande): a = u + v,  b = (u - v) w
// u, v canonical in [0, P); wc is the centred stored constant (see modmul).
module bfly #(
  parameter int P   = 249857,
  parameter int RED = ntt_pkg::RED_MONT,
  parameter int DIR = 0
) (
  input  logic               clk,
  input  logic        [17:0] u,
  input  logic        [17:0] v,
  input  logic signed [17:0] wc,
  output logic        [17:0] a,
  output logic        [17:0] b
);
  localparam int ML = ntt_pkg::mul_lat(RED);
  localparam logic [18:0] P19 = 19'(P);

  if (DIR == 0) begin : g_ct
    logic [17:0] t;
    logic [17:0] ud [ML];
    modmul #(.P(P), .RED(RED)) u_mul (.clk(clk), .x(v), .wc(wc), .r(t));
    always_ff @(posedge clk) begin
      ud[0] <= u;
      for (int i = 1; i < ML; i++) ud[i] <= ud[i-1];
      a <= 18'(ntt_pkg::mod_add(ud[ML-1], t, P19));
      b <= 18'(ntt_pkg::mod_sub(ud[ML-1], t, P19));
    end
  end else begin : g_gs
    logic        [17:0] s1, d1;
    logic signed [17:0] w1;
    logic        [17:0] sd [ML];
    modmul #(.P(P), .RED(RED)) u_mul (.clk(clk), .x(d1), .wc(w1), .r(b));
    always_ff @(posedge clk) begin
      s1 <= 18'(ntt_pkg::mod_add(u, v, P19));
      d1 <= 18'(ntt_pkg::mod_sub(u, v, P19));
      w1 <= wc;
      sd[0] <= s1;
      for (int i = 1; i < ML; i++) sd[i] <= sd[i-1];
    end
    assign a = sd[ML-1];
  end
endmodule
