// Testbench-only AXI4 read slave standing in for one DDR4 channel behind its SmartConnect:
// 512-bit beats from $readmemh (load task), base address BASE, up to 8 bursts queued, a random
// latency (LAT_MIN..LAT_MAX cycles from AR, overlapping earlier bursts) per burst and random RVALID gaps (GAP_PCT %).
// Drives at negedge, samples at negedge (TB discipline). Flags out-of-range reads.
`timescale 1ps/1ps
module axi_ddr_model #(
  parameter int      DEPTH   = 1024,
  parameter longint  BASE    = 0,
  parameter int      LAT_MIN = 20,
  parameter int      LAT_MAX = 60,
  parameter int      GAP_PCT = 10
) (
  input  logic         clk,
  input  logic [33:0]  araddr,
  input  logic [7:0]   arlen,
  input  logic [2:0]   arsize,
  input  logic [1:0]   arburst,
  input  logic         arvalid,
  output logic         arready,
  output logic [511:0] rdata,
  output logic [1:0]   rresp,
  output logic         rlast,
  output logic         rvalid,
  input  logic         rready
);
  logic [511:0] mem [DEPTH];
  longint q_addr [$];
  int     q_len  [$];
  longint q_t    [$];                // cycle at which the burst's first beat may go out
  longint cyc = 0;
  longint cur;
  int     left, bad = 0;
  longint beats = 0;
  bit     active = 0;
  initial begin
    arready = 0; rvalid = 0; rlast = 0; rresp = 0; rdata = '0;
  end
  task automatic load(input string f);
    $readmemh(f, mem);
  endtask
  always @(negedge clk) begin
    cyc++;
    // address channel: a handshake happened at the last posedge if both were high
    if (arvalid && arready) begin
      if (arsize != 3'b110 || arburst != 2'b01) begin bad++; $display("ERROR %m: arsize %0d arburst %0d", arsize, arburst); end
      q_addr.push_back(longint'(araddr));
      q_len.push_back(int'(arlen) + 1);
      q_t.push_back(cyc + longint'($urandom_range(LAT_MAX, LAT_MIN)));   // latency overlaps earlier bursts
    end
    arready = (q_addr.size() < 8);
    // data channel: a beat once shown is held until it is taken
    if (rvalid && rready) begin
      beats++;
      left--;
      cur += 64;
      if (left == 0) active = 0;
      rvalid = 0; rlast = 0;
    end
    if (!rvalid) begin
      if (!active && q_addr.size() > 0 && cyc >= q_t[0]) begin
        cur = q_addr.pop_front(); left = q_len.pop_front(); active = 1;
        void'(q_t.pop_front());
      end
      if (active) begin
        if ($urandom_range(99, 0) >= GAP_PCT) begin
          longint idx;
          idx = (cur - BASE) / 64;
          if (idx < 0 || idx >= DEPTH) begin
            if (bad < 4) $display("ERROR %m: read at 0x%0h outside the image", cur);
            bad++;
            rdata = '0;
          end else rdata = mem[idx];
          rvalid = 1; rlast = (left == 1);
        end
      end
    end
  end
endmodule
