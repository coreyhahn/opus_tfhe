// opus_tfhe transform-core constants. Arithmetic contract: docs/PARAMS.md, ref/tfhe_model/src/ntt_q.rs.
package ntt_pkg;
  localparam int N     = 2048;
  localparam int LOG_N = 11;
  localparam int W     = 18;          // residue width; every prime is < 2^18

  // Reduction styles of modmul. MONT: constants stored as w*2^18 mod p; TABLE: as w.
  localparam int RED_MONT  = 0;
  localparam int RED_TABLE = 1;

  function automatic int mul_lat(input int red);
    return (red == RED_MONT) ? 10 : 7;
  endfunction

  // butterfly = one modmul + one modular add/sub register
  function automatic int bfly_lat(input int red);
    return mul_lat(red) + 1;
  endfunction

  function automatic logic [W:0] mod_add(input logic [W-1:0] a, input logic [W-1:0] b, input logic [W:0] p);
    logic [W:0] s;
    logic [W+1:0] d;
    s = {1'b0, a} + {1'b0, b};
    d = {1'b0, s} - {1'b0, p};
    return d[W+1] ? s : d[W:0];
  endfunction

  function automatic logic [W:0] mod_sub(input logic [W-1:0] a, input logic [W-1:0] b, input logic [W:0] p);
    logic [W:0] d;
    d = {1'b0, a} - {1'b0, b};
    return d[W] ? d + p : d;
  endfunction
endpackage
