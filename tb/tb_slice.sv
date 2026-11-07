// acc_slice against the model (dump_engine slice): INIT every slot, a CMUX sequence on random slots
// with random rotations (every diff frame checked, the model's O fed back to accumulate), then
// EXTRACT every slot (sample-extracted mask and body[0] checked).
// Compile: -GPLOG=5 -GBSLOG=2 -GPRIME=249857   Run: +vec=<dir>
`timescale 1ns/1ps
module tb_slice #(parameter int PLOG = 5, parameter int BSLOG = 2, parameter int PRIME = 249857);
  localparam int PP = 1 << PLOG;
  localparam int FR = 2048 / PP;
  localparam int W  = PP * 18;
  logic clk = 0, rst = 1;
  always #1 clk = ~clk;

  logic lut_we = 0, cmd_start = 0, a_valid = 0, a_sof = 0;
  logic [10-PLOG:0] lut_addr;
  logic [W-1:0] lut_wdata, o0, o1, d0, d1;
  logic [1:0] cmd_type, a_type, d_type;
  logic [BSLOG-1:0] cmd_slot, a_slot, d_slot;
  logic [11:0] cmd_rot, a_rot, d_rot;
  logic d_valid, d_sof;

  acc_slice #(.P(PRIME), .PLOG(PLOG), .BSLOG(BSLOG)) dut (
    .clk(clk), .rst(rst), .lut_we(lut_we), .lut_addr(lut_addr), .lut_wdata(lut_wdata),
    .cmd_start(cmd_start), .cmd_type(cmd_type), .cmd_slot(cmd_slot), .cmd_rot(cmd_rot),
    .d_valid(d_valid), .d_sof(d_sof), .d_type(d_type), .d_slot(d_slot), .d_rot(d_rot), .d0(d0), .d1(d1),
    .a_valid(a_valid), .a_sof(a_sof), .a_type(a_type), .a_slot(a_slot), .a_rot(a_rot), .o0(o0), .o1(o1));

  logic [W-1:0] lut [FR];
  logic [W-1:0] ov [1 << 16], dv [1 << 16], ev [1 << 14], ai [1 << 12];
  bit dbg;
  int op_t [256], op_c [256], op_r [256];
  int nops = 0, errors = 0, frames = 0;
  string vec;

  task automatic run_frame(input int ty, input int slot, input int rot);
    @(negedge clk);
    cmd_start <= 1;
    cmd_type <= 2'(ty);
    cmd_slot <= BSLOG'(slot);
    cmd_rot <= 12'(rot);
    @(negedge clk);
    cmd_start <= 0;
  endtask

  // accumulate one frame: type, slot, rot; O frames from ov at index oi (or zeros when oi < 0)
  task automatic acc_frame(input int ty, input int slot, input int rot, input int oi);
    for (int t = 0; t < FR; t++) begin
      @(negedge clk);
      a_valid <= 1;
      a_sof <= (t == 0);
      a_type <= 2'(ty);
      a_slot <= BSLOG'(slot);
      a_rot <= 12'(rot);
      o0 <= (oi < 0) ? '0 : ov[oi + t];
      o1 <= (oi < 0) ? '0 : ov[oi + FR + t];
    end
    @(negedge clk);
    a_valid <= 0;
    a_sof <= 0;
    repeat (8) @(negedge clk);       // let the writes land before the next read
  endtask

  // collect the read-side frame and compare: expect0/1 from arrays (index, or -1 to skip poly 1)
  task automatic check_frame(input int ty, input int di, input int ei);
    int got = 0;
    while (got < FR) begin
      @(negedge clk);
      if (d_valid) begin
        if (d_sof !== (got == 0)) begin errors++; $display("ERROR sof at %0d", got); end
        if (ty == 0) begin
          if (d0 !== dv[di + got] || d1 !== dv[di + FR + got]) begin
            if (errors < 6) $display("ERROR CMUX frame %0d tau %0d: d0[0]=%h want %h d1[0]=%h want %h", frames, got, d0[17:0], dv[di+got][17:0], d1[17:0], dv[di+FR+got][17:0]);
            errors++;
          end
        end else if (ty == 2) begin
          if (d0 !== ev[ei + got]) begin
            if (errors < 6) $display("ERROR EXTRACT mask tau %0d: got %h want %h", got, d0, ev[ei + got]);
            errors++;
          end
          if (got == 0 && d1[17:0] !== ev[ei + FR][17:0]) begin
            if (errors < 6) $display("ERROR EXTRACT body[0]: got %h want %h", d1[17:0], ev[ei + FR][17:0]);
            errors++;
          end
        end else if (d0 !== '0 || d1 !== '0) errors++;
        got++;
      end
    end
    frames++;
  endtask

  initial begin
    int fd, t, c, r, di = 0, oi = 0, ei = 0;
    if (!$value$plusargs("vec=%s", vec)) $fatal(1, "+vec=<dir> required");
    $readmemh({vec, "/lut.hex"}, lut);
    $readmemh({vec, "/o.hex"}, ov);
    $readmemh({vec, "/diff.hex"}, dv);
    $readmemh({vec, "/extract.hex"}, ev);
    dbg = $test$plusargs("debug");
    if (dbg) $readmemh({vec, "/acc_init.hex"}, ai);
    fd = $fopen({vec, "/ops.txt"}, "r");
    while ($fscanf(fd, "%d %d %d\n", t, c, r) == 3) begin
      op_t[nops] = t; op_c[nops] = c; op_r[nops] = r; nops++;
    end
    $fclose(fd);
    repeat (3) @(negedge clk);
    rst = 0;
    for (int i = 0; i < FR; i++) begin
      @(negedge clk);
      lut_we <= 1;
      lut_addr <= (11 - PLOG)'(i);
      lut_wdata <= lut[i];
    end
    @(negedge clk);
    lut_we <= 0;
    for (int k = 0; k < nops; k++) begin
      // sequential on purpose: the frame's first output comes 4 cycles after cmd_start, the
      // checker starts 2 cycles after it (a fork here crashed Verilator 5.020's coroutines)
      run_frame(op_t[k], op_c[k], op_r[k]);
      check_frame(op_t[k], di, ei);
      if (op_t[k] == 0) begin
        acc_frame(0, op_c[k], op_r[k], oi);
        di += 2 * FR;
        oi += 2 * FR;
      end else if (op_t[k] == 1) begin
        acc_frame(1, op_c[k], op_r[k], -1);
      end else begin
        ei += FR + 1;
      end
      // debug: after the INITs, read every slot back unrotated (EXTRACT d1) against acc_init.hex
      if (dbg && k == (1 << BSLOG) - 1) begin
        for (int c2 = 0; c2 < (1 << BSLOG); c2++) begin
          int got2 = 0;
          run_frame(2, c2, 0);
          while (got2 < FR) begin
            @(negedge clk);
            if (d_valid) begin
              if (d1 !== ai[c2 * FR + got2] && errors < 6) begin
                $display("DBG slot %0d tau %0d: body lane0 %h want %h", c2, got2, d1[17:0], ai[c2 * FR + got2][17:0]);
                errors++;
              end
              got2++;
            end
          end
        end
        $display("DBG init readback done, errors=%0d", errors);
      end
    end
    if (errors != 0) $fatal(1, "tb_slice FAILED: %0d errors", errors);
    $display("PASS tb_slice P=%0d prime=%0d slots=%0d ops=%0d frames=%0d", PP, PRIME, 1 << BSLOG, nops, frames);
    $finish;
  end
endmodule
