// digit_unit against the model (dump_engine digits): every sample of the file is checked; a third
// of them sit next to rounding boundaries. Run: +vec=<file>; LANES is compile-time (-GLANES).
`timescale 1ns/1ps
module tb_digit #(parameter int LANES = 4);
  localparam int LAT = 5;
  localparam int MAXS = 1 << 20;
  logic clk = 0;
  always #1 clk = ~clk;
  logic [LANES*18-1:0] y0, y1, y2;
  logic [LANES*24-1:0] d;
  digit_unit #(.LANES(LANES)) dut (.clk(clk), .y0(y0), .y1(y1), .y2(y2), .d(d));
  string vec;
  int fd, ns = 0, errors = 0, checked = 0;
  logic [17:0] ya [MAXS], yb [MAXS], yc [MAXS];
  logic [23:0] de [MAXS];
  initial begin
    int a, b, c, e;
    if (!$value$plusargs("vec=%s", vec)) $fatal(1, "+vec=<file> required");
    fd = $fopen(vec, "r");
    if (fd == 0) $fatal(1, "cannot open %s", vec);
    while (ns < MAXS && $fscanf(fd, "%h %h %h %h\n", a, b, c, e) == 4) begin
      ya[ns] = 18'(a); yb[ns] = 18'(b); yc[ns] = 18'(c); de[ns] = 24'(e);
      ns++;
    end
    $fclose(fd);
    // beat k carries samples k*LANES .. k*LANES+LANES-1; output of beat k is valid LAT cycles later
    for (int k = 0; k < (ns + LANES - 1) / LANES + LAT; k++) begin
      @(negedge clk);
      for (int l = 0; l < LANES; l++) begin
        int i;
        i = k * LANES + l;
        y0[l*18 +: 18] = (i < ns) ? ya[i] : '0;
        y1[l*18 +: 18] = (i < ns) ? yb[i] : '0;
        y2[l*18 +: 18] = (i < ns) ? yc[i] : '0;
        i = (k - LAT) * LANES + l;
        if (k >= LAT && i < ns) begin
          if (d[l*24 +: 24] !== de[i]) begin
            if (errors < 8) $display("ERROR sample %0d: got %h want %h", i, d[l*24 +: 24], de[i]);
            errors++;
          end
          checked++;
        end
      end
    end
    if (errors != 0 || checked != ns) $fatal(1, "tb_digit FAILED: %0d errors, %0d of %0d checked", errors, checked, ns);
    $display("PASS tb_digit %0d of %0d samples, LANES=%0d", checked, ns, LANES);
    $finish;
  end
endmodule
