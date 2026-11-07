// Small synchronous FIFO, first-word fall-through (head valid whenever count != 0).
// Push when full or pop when empty is a design error (asserted in simulation).
module sfifo #(
  parameter int W     = 18,
  parameter int DEPTH = 8          // power of two
) (
  input  logic         clk,
  input  logic         rst,
  input  logic         push,
  input  logic [W-1:0] din,
  input  logic         pop,
  output logic [W-1:0] head,
  output logic [$clog2(DEPTH):0] count
);
  localparam int AB = $clog2(DEPTH);
  logic [W-1:0]  mem [DEPTH];
  logic [AB-1:0] rp, wp;
  always_ff @(posedge clk) begin
    if (push) mem[wp] <= din;
    if (rst) begin
      rp <= '0;
      wp <= '0;
      count <= '0;
    end else begin
      if (push) wp <= wp + 1'b1;
      if (pop)  rp <= rp + 1'b1;
      count <= count + (AB+1)'(push) - (AB+1)'(pop);
    end
  end
  assign head = mem[rp];
  // synthesis translate_off
  always @(posedge clk) if (!rst) begin
    if (push && !pop && count == (AB+1)'(DEPTH)) $fatal(1, "sfifo %m: overflow");
    if (pop && count == 0) $fatal(1, "sfifo %m: underflow");
  end
  // synthesis translate_on
endmodule
