// Self-checking test of modmul: all three primes x both reductions, random and edge operands,
// against 64-bit reference arithmetic. Inputs change and outputs are sampled on negedge only.
// +seed=<n> +count=<n per instance>
`timescale 1ns/1ps
module tb_modmul_one #(parameter int P = 249857, parameter int RED = 0) (
  input logic clk, input logic run, output int errors, output int checked
);
  localparam int LAT = ntt_pkg::mul_lat(RED);
  localparam longint C = (RED == ntt_pkg::RED_MONT) ? ((64'(1) << 18) % 64'(P)) : 1;
  logic        [17:0] x;
  logic signed [17:0] wc;
  logic        [17:0] r;
  longint expq [$];

  modmul #(.P(P), .RED(RED)) dut (.clk(clk), .x(x), .wc(wc), .r(r));

  function automatic longint pick(input int k);
    case (k)
      0: return 0;
      1: return 1;
      2: return P - 1;
      3: return (P - 1) / 2;
      4: return (P + 1) / 2;
      default: return longint'($urandom) % P;
    endcase
  endfunction

  initial begin
    errors = 0;
    checked = 0;
  end

  int n = 0;
  always @(negedge clk) if (run) begin
    longint xv, wv, wcv;
    xv = pick(n < 25 ? n % 5 : 9);
    wv = pick(n < 25 ? n / 5 : 9);
    wcv = (wv * C) % P;
    if (wcv > P / 2) wcv = wcv - P;
    x  <= 18'(xv);
    wc <= 18'(wcv);
    expq.push_back((xv * wv) % P);
    n++;
    if (expq.size() > LAT) begin
      longint e;
      e = expq.pop_front();
      if (longint'(r) != e) begin
        if (errors < 10) $display("ERROR P=%0d RED=%0d n=%0d got %0d want %0d", P, RED, n, r, e);
        errors++;
      end
      checked++;
    end
  end
endmodule

module tb_modmul;
  logic clk = 0;
  always #1 clk = ~clk;
  logic run = 0;
  int seed, count;
  int err [6];
  int chk [6];
  localparam int PR [3] = '{249857, 188417, 163841};

  for (genvar i = 0; i < 3; i++) begin : g_p
    for (genvar red = 0; red < 2; red++) begin : g_r
      tb_modmul_one #(.P(PR[i]), .RED(red)) u (.clk(clk), .run(run), .errors(err[2*i+red]), .checked(chk[2*i+red]));
    end
  end

  initial begin
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    if (!$value$plusargs("count=%d", count)) count = 200000;
    void'($urandom(seed));
    @(negedge clk);
    run = 1;
    repeat (count) @(negedge clk);
    run = 0;
    @(negedge clk);
    for (int k = 0; k < 6; k++) begin
      $display("P=%0d RED=%s checked=%0d errors=%0d", PR[k/2], (k % 2) ? "TABLE" : "MONT", chk[k], err[k]);
      if (err[k] != 0 || chk[k] < count - 20) $fatal(1, "modmul FAILED");
    end
    $display("PASS tb_modmul seed=%0d", seed);
    $finish;
  end
endmodule
