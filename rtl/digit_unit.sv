// Gadget digit (pbs_level = 1, base 2^23) of an accumulator coefficient given as y-form RNS
// residues: d = round(x 2^23 / Q) mod 2^23, centred in [-2^22, 2^22), by approximate CRT with
// F = 28 fractional bits (docs/PARAMS.md; bit-exact target Rns::digit / Engine::digit_y).
//   s = sum_i y_i K_i, K_i = round(2^(23+F) / p_i) < 2^34, split K_i = K_hi,i 2^17 + K_lo,i.
//   The DSP48E2-shaped evaluation sum_i y_i K_hi,i + floor(sum_i y_i K_lo,i / 2^17) = floor(s / 2^17)
//   is exact, so d = ((floor(s / 2^17) + 2^(F-18)) >> (F-17)) mod 2^23 equals the model's
//   ((s + 2^(F-1)) >> F) mod 2^23. Latency 5, one coefficient per lane per cycle.
module digit_unit #(
  parameter int LANES = 1
) (
  input  logic                  clk,
  input  logic [LANES*18-1:0]   y0,      // residue mod 249857 (y-form)
  input  logic [LANES*18-1:0]   y1,      // residue mod 188417
  input  logic [LANES*18-1:0]   y2,      // residue mod 163841
  output logic [LANES*24-1:0]   d        // signed digit, 24-bit two's complement
);
  localparam int F = 28;
  localparam longint PR [3] = '{249857, 188417, 163841};
  function automatic longint kconst(input logic [1:0] i);
    return ((64'(1) << (23 + F)) + PR[i] / 2) / PR[i];
  endfunction
  localparam logic [16:0] KLO [3] = '{17'(kconst(0)), 17'(kconst(1)), 17'(kconst(2))};
  localparam logic [16:0] KHI [3] = '{17'(kconst(0) >> 17), 17'(kconst(1) >> 17), 17'(kconst(2) >> 17)};

  for (genvar l = 0; l < LANES; l++) begin : g_l
    logic [17:0] ya [3];
    logic [34:0] plo [3], phi [3];
    logic [36:0] slo;
    logic [36:0] phs;
    logic [37:0] s17;
    always_ff @(posedge clk) begin
      ya[0] <= y0[l*18 +: 18];
      ya[1] <= y1[l*18 +: 18];
      ya[2] <= y2[l*18 +: 18];
      for (int i = 0; i < 3; i++) begin
        plo[i] <= 35'(ya[i]) * 35'(KLO[i]);
        phi[i] <= 35'(ya[i]) * 35'(KHI[i]);
      end
      slo <= 37'(plo[0]) + 37'(plo[1]) + 37'(plo[2]);
      phs <= 37'(phi[0]) + 37'(phi[1]) + 37'(phi[2]);
      s17 <= 38'(phs) + (38'(slo) >> 17);
      d[l*24 +: 24] <= 24'($signed(23'((s17 + 38'(1 << (F - 18))) >> (F - 17))));
    end
  end
endmodule
