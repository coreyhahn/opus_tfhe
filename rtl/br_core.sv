// Blind-rotation core (docs/ARCHITECTURE.md §3, §4.3): three residue slices, the digit unit, the
// streaming external product, and the frame sequencer. Bit-exact target: Engine::blind_rotate
// (ref/tfhe_model/src/engine.rs) up to the y-form EXTRACT stream (psi follows in 4.4).
//
// Batch: 2^BSLOG ciphertext slots, NC CMuxes. Before `start`, the host side has loaded:
//   - the y-form LUT of each residue (lut_*), and the modulus-switched inputs (ms_*: NC masks,
//     then the body at index NC, each in [0, 2N));
//   - BSK operands, which are loaded on request: bsk_req pulses (bsk_req_idx, bsk_req_buf); the
//     host writes the FR words of each residue into that buffer (op_*) and pulses bsk_done.
// Frames are issued one per FR cycles:
//   - INIT for every slot;
//   - then CMux i = 0..NC-1, one frame per slot (round robin; a slot's frames are TDEP cycles
//     apart so its previous accumulate has landed);
//   - then EXTRACT for every slot. The y-form sample-extracted mask (3 residues x P lanes per
//     cycle, FR cycles) and body[0] (lane 0 of the first cycle) come out on ex_*.
module br_core #(
  parameter int    RED    = ntt_pkg::RED_MONT,
  parameter int    RED_F  = RED,          // forward NTT pipelines
  parameter int    RED_M  = RED,          // MAC (BSK operands stored in this representation)
  parameter int    RED_I  = RED,          // inverse NTT pipelines
  parameter int    PLOG   = 5,
  parameter int    BSLOG  = 3,
  parameter int    NC     = 918,
  parameter string ROMDIR = "",
  parameter string ROMDIR_F = ROMDIR,
  parameter string ROMDIR_I = ROMDIR,
  parameter int    TDEP_OVERRIDE = 0,      // 0: computed from the pipeline latencies
  parameter logic [31:0] CYC_RST = '0      // sim only: reset value of the frame-schedule counter cyc
) (
  input  logic                           clk,
  input  logic                           rst,
  input  logic                           lut_we,
  input  logic [1:0]                     lut_res,
  input  logic [ntt_pkg::LOG_N-PLOG-1:0] lut_addr,
  input  logic [(1<<PLOG)*18-1:0]        lut_wdata,
  input  logic                           ms_we,
  input  logic                           ms_bank,      // two banks: KS fills one while BR reads the other
  input  logic [BSLOG-1:0]               ms_slot,
  input  logic [9:0]                     ms_idx,       // 0..NC (NC <= 1023)
  input  logic [ntt_pkg::LOG_N:0]        ms_val,
  input  logic                           start,
  input  logic                           start_bank,
  output logic                           busy,
  output logic                           done,
  output logic                           bsk_req,
  output logic [10:0]                    bsk_req_idx,
  output logic                           bsk_req_buf,
  input  logic                           op_we,
  input  logic                           op_buf,
  input  logic [ntt_pkg::LOG_N-PLOG-1:0] op_addr,
  input  logic [3*4*(1<<PLOG)*18-1:0]    op_wdata,
  input  logic                           bsk_done,
  output logic                           ex_valid,
  output logic                           ex_sof,
  output logic [BSLOG-1:0]               ex_slot,
  output logic [3*(1<<PLOG)*18-1:0]      ex_d,
  output logic [3*18-1:0]                ex_body
);
  localparam int PP = 1 << PLOG;
  localparam int FB = ntt_pkg::LOG_N - PLOG;
  localparam int FR = 1 << FB;
  localparam int BS = 1 << BSLOG;
  localparam int RB = ntt_pkg::LOG_N + 1;
  localparam int TWO_N = 2 * ntt_pkg::N;
  localparam int ML = ntt_pkg::mul_lat(RED_M);
  // issue -> last accumulate write of the frame, plus the frame itself, plus margin
  localparam int LPF = FR - 1 + ntt_pkg::LOG_N * (1 + ntt_pkg::bfly_lat(RED_F));   // forward ntt_pipe
  localparam int LPI = FR - 1 + ntt_pkg::LOG_N * (1 + ntt_pkg::bfly_lat(RED_I));   // inverse ntt_pipe
  // SLR-crossing register stages (the slices and xpipe residues sit in their residue's SLR, the
  // digit unit and this sequencer do not): XD before and after the digit unit, AR on the
  // accumulate side here (acc_slice adds one more on each of its sides).
  localparam int XD = 2;
  localparam int AR = 1;
  localparam int TLOOP = 7 + 1 + (5 + 2 * XD) + 3 + LPF + LPI + (3 + ML) + AR + 8;   // acc_slice read 7, xpipe3 digit reduction 3, xpipe1 MAC 3+ML, accumulate 7+1
  localparam int TDEP  = (TDEP_OVERRIDE > 0) ? TDEP_OVERRIDE : TLOOP + FR + 16;
  localparam int    PR [3] = '{249857, 188417, 163841};

  typedef enum logic [2:0] {S_IDLE, S_INIT, S_LOOP, S_EXT, S_DRAIN} state_e;

  // ------------------------------------------------------------------ ms RAM
  logic [RB-1:0] msram [2 * BS * 1024];
  logic [RB-1:0] ms_q;
  logic [BSLOG+10:0] ms_raddr;
  logic          rbank;
  always_ff @(posedge clk) begin
    if (ms_we) msram[{ms_bank, ms_slot, ms_idx}] <= ms_val;
    ms_q <= msram[ms_raddr];
  end

  // ------------------------------------------------------------------ slices
  logic            cmd_start;
  logic [1:0]      cmd_type;
  logic [BSLOG-1:0] cmd_slot;
  logic [RB-1:0]   cmd_rot;
  logic [2:0]      dv, ds;
  logic [1:0]      dty [3];
  logic [BSLOG-1:0] dsl [3];
  logic [RB-1:0]   drot [3];
  logic [PP*18-1:0] sd0 [3], sd1 [3];
  logic            a_valid, a_sof;
  logic [1:0]      a_type;
  logic [BSLOG-1:0] a_slot;
  logic [RB-1:0]   a_rot;
  logic [3*PP*18-1:0] xo0, xo1;

  for (genvar i = 0; i < 3; i++) begin : g_s
    acc_slice #(.P(PR[i]), .PLOG(PLOG), .BSLOG(BSLOG)) u_sl (
      .clk(clk), .rst(rst), .lut_we(lut_we && lut_res == 2'(i)), .lut_addr(lut_addr), .lut_wdata(lut_wdata),
      .cmd_start(cmd_start), .cmd_type(cmd_type), .cmd_slot(cmd_slot), .cmd_rot(cmd_rot),
      .d_valid(dv[i]), .d_sof(ds[i]), .d_type(dty[i]), .d_slot(dsl[i]), .d_rot(drot[i]), .d0(sd0[i]), .d1(sd1[i]),
      .a_valid(a_valid), .a_sof(a_sof), .a_type(a_type), .a_slot(a_slot), .a_rot(a_rot),
      .o0(xo0[i*PP*18 +: PP*18]), .o1(xo1[i*PP*18 +: PP*18]));
  end
  wire unused_twins = ^{dv[2:1], ds[2:1], dty[1], dty[2], dsl[1], dsl[2], drot[0], drot[1], drot[2]};

  // ------------------------------------------------------------------ frame tags (issue -> read out)
  // the tag of a frame is popped on its first beat and held for the rest of it
  logic tq [16];
  logic [3:0] tq_wr, tq_rd;
  logic d_tag, d_tag_r;
  assign d_tag = ds[0] ? tq[tq_rd] : d_tag_r;
  always_ff @(posedge clk) if (ds[0]) d_tag_r <= tq[tq_rd];

  // ------------------------------------------------------------------ digits (latency 5)
  logic [2*PP*24-1:0] dig, dig_u;
  logic [2*PP*18-1:0] yin [3][XD];
  logic [2*PP*24-1:0] dout [XD];
  always_ff @(posedge clk) begin
    for (int i = 0; i < 3; i++) begin
      yin[i][0] <= {sd1[i], sd0[i]};
      for (int k = 1; k < XD; k++) yin[i][k] <= yin[i][k-1];
    end
    dout[0] <= dig_u;
    for (int k = 1; k < XD; k++) dout[k] <= dout[k-1];
  end
  digit_unit #(.LANES(2 * PP)) u_dig (
    .clk(clk), .y0(yin[0][XD-1]), .y1(yin[1][XD-1]), .y2(yin[2][XD-1]), .d(dig_u));
  assign dig = dout[XD-1];
  localparam int DL = 5 + 2 * XD;
  logic xv [DL], xs [DL], xt [DL];
  always_ff @(posedge clk) begin
    xv[0] <= dv[0] && (dty[0] != 2'd2);
    xs[0] <= ds[0] && (dty[0] != 2'd2);
    xt[0] <= d_tag;
    for (int k = 1; k < DL; k++) begin
      xv[k] <= xv[k-1]; xs[k] <= xs[k-1]; xt[k] <= xt[k-1];
    end
  end

  logic xov, xos, mdone, mtag;
  logic [3*PP*18-1:0] xp0, xp1;
  xpipe3 #(.RED_F(RED_F), .RED_M(RED_M), .RED_I(RED_I), .PLOG(PLOG), .ROMDIR_F(ROMDIR_F), .ROMDIR_I(ROMDIR_I)) u_xp (
    .clk(clk), .op_we(op_we), .op_buf(op_buf), .op_addr(op_addr), .op_wdata(op_wdata),
    .in_valid(xv[DL-1]), .in_sof(xs[DL-1]), .in_tag(xt[DL-1]), .in_d0(dig[PP*24-1:0]), .in_d1(dig[2*PP*24-1:PP*24]),
    .mac_done(mdone), .mac_done_tag(mtag), .out_valid(xov), .out_sof(xos), .out_o0(xp0), .out_o1(xp1));

  // ------------------------------------------------------------------ accumulate metadata (in order)
  logic [1+BSLOG+RB:0] mq [16];
  logic [3:0] mq_wr, mq_rd;
  // registered here (AR = 1) on the way back to the slices
  always_ff @(posedge clk) begin
    a_valid <= xov && !rst;
    a_sof   <= xos && !rst;
    {a_type, a_slot, a_rot} <= mq[mq_rd];
    xo0 <= xp0;
    xo1 <= xp1;
  end

  // ------------------------------------------------------------------ EXTRACT output
  // two register stages: the slices are in three SLRs, psi is not
  logic                 e_valid, e_sof;
  logic [BSLOG-1:0]     e_slot;
  logic [PP*18-1:0]     e_d [3];        // per residue: the first stage is placed in its SLR
  logic [17:0]          e_body [3];
  always_ff @(posedge clk) begin
    e_valid  <= dv[0] && (dty[0] == 2'd2) && !rst;
    e_sof    <= ds[0] && (dty[0] == 2'd2) && !rst;
    e_slot   <= dsl[0];
    for (int i = 0; i < 3; i++) begin
      e_d[i]    <= sd0[i];
      e_body[i] <= sd1[i][17:0];
    end
    ex_valid <= e_valid && !rst;
    ex_sof   <= e_sof && !rst;
    ex_slot  <= e_slot;
    ex_d     <= {e_d[2], e_d[1], e_d[0]};
    ex_body  <= {e_body[2], e_body[1], e_body[0]};
  end

  // ------------------------------------------------------------------ sequencer
  state_e         st;
  logic [10:0]    cur;
  logic [BSLOG-1:0] slot;
  logic [15:0]    fbusy;                  // cycles until the next frame may start
  logic [31:0]    cyc;
  logic [31:0]    ready_t [BS];
  logic           prep;                   // ms read issued, value arrives next cycle
  logic [BSLOG+FB:0] ex_beats;          // EXTRACT beats emitted (done after the last one)
  // BSK buffers
  logic [10:0]    next_load;
  logic           lreq;
  logic [10:0]    ld_idx [2];
  logic           ld_ok [2];
  logic [15:0]    issued [2], dcnt [2];

  wire        cb = cur[0];
  wire        want_frame = (st == S_INIT) || (st == S_EXT) ||
                           (st == S_LOOP && ld_ok[cb] && ld_idx[cb] == cur);
  wire        slot_ready = (cyc >= ready_t[slot]);
  wire        lb = next_load[0];
  wire        buf_free = !ld_ok[lb] ||
                         (ld_idx[lb] + 11'd2 == next_load && cur > ld_idx[lb] && dcnt[lb] == issued[lb]);

  always_comb ms_raddr = {rbank, slot, (st == S_INIT) ? 10'(NC) : (st == S_LOOP ? cur[9:0] : 10'd0)};

  // the operand RAM write is registered in xpipe1 (residue side of the SLR crossing): bsk_done follows it
  logic bsk_done_q;
  always_ff @(posedge clk) bsk_done_q <= bsk_done && !rst;
  always_ff @(posedge clk) begin
    cmd_start <= 1'b0;
    bsk_req <= 1'b0;
    done <= 1'b0;
    if (rst) begin
      st <= S_IDLE; cyc <= CYC_RST; fbusy <= '0; prep <= 1'b0; busy <= 1'b0;
      tq_wr <= '0; tq_rd <= '0; mq_wr <= '0; mq_rd <= '0;
      lreq <= 1'b0; next_load <= '0; ld_ok[0] <= 1'b0; ld_ok[1] <= 1'b0;
      issued[0] <= '0; issued[1] <= '0; dcnt[0] <= '0; dcnt[1] <= '0;
    end else begin
      cyc <= cyc + 1;
      if (fbusy != 0) fbusy <= fbusy - 1'b1;
      // ---- BSK loading, one request outstanding
      if (busy && !lreq && next_load < 11'(NC) && buf_free) begin
        bsk_req <= 1'b1;
        bsk_req_idx <= next_load;
        bsk_req_buf <= lb;
        ld_ok[lb] <= 1'b0;
        lreq <= 1'b1;
      end
      if (bsk_done_q) begin
        ld_ok[bsk_req_buf] <= 1'b1;
        ld_idx[bsk_req_buf] <= bsk_req_idx;
        next_load <= next_load + 1'b1;
        lreq <= 1'b0;
      end
      if (mdone) dcnt[mtag] <= dcnt[mtag] + 1'b1;
      // ---- read-side tags and accumulate metadata
      if (ds[0]) tq_rd <= tq_rd + 1'b1;
      if (ds[0] && dty[0] != 2'd2) begin
        mq[mq_wr] <= {dty[0], dsl[0], drot[0]};
        mq_wr <= mq_wr + 1'b1;
      end
      if (xos) mq_rd <= mq_rd + 1'b1;
      if (ex_valid) ex_beats <= ex_beats + 1'b1;
      // ---- frame issue: prepare (read ms) then issue
      case (st)
        S_IDLE: if (start) begin
          st <= S_INIT; slot <= '0; cur <= '0; busy <= 1'b1; ex_beats <= '0; rbank <= start_bank;
          // cyc restarts per batch (~1M cycles), so cyc >= ready_t never straddles the 32-bit wrap:
          // free-running, it stalled a slot for 2^32 cycles on silicon (2026-11-03, tb make brwrap)
          cyc <= '0;
          for (int c = 0; c < BS; c++) ready_t[c] <= '0;
          // BSK loader restarts per batch (the previous batch's MACs have all completed by done)
          next_load <= '0; ld_ok[0] <= 1'b0; ld_ok[1] <= 1'b0;
          issued[0] <= '0; issued[1] <= '0; dcnt[0] <= '0; dcnt[1] <= '0;
        end
        S_DRAIN: if (ex_beats == (BSLOG+FB+1)'(BS * FR)) begin
          st <= S_IDLE; busy <= 1'b0; done <= 1'b1;
        end
        default: begin
          if (!prep) begin
            if (fbusy == 0 && want_frame && slot_ready) prep <= 1'b1;
          end else begin
            prep <= 1'b0;
            cmd_start <= 1'b1;
            cmd_slot  <= slot;
            fbusy     <= 16'(FR - 1);
            ready_t[slot] <= cyc + 32'(TDEP);
            tq[tq_wr] <= (st == S_LOOP) ? cb : 1'b0;
            tq_wr <= tq_wr + 1'b1;
            case (st)
              S_INIT: begin
                cmd_type <= 2'd1;
                cmd_rot  <= RB'((TWO_N - int'(ms_q)) % TWO_N);
                issued[0] <= issued[0] + 1'b1;
              end
              S_LOOP: begin
                cmd_type <= 2'd0;
                cmd_rot  <= ms_q;
                issued[cb] <= issued[cb] + 1'b1;
              end
              default: begin
                cmd_type <= 2'd2;
                cmd_rot  <= '0;
              end
            endcase
            if (slot == BSLOG'(BS - 1)) begin
              slot <= '0;
              if (st == S_INIT) st <= S_LOOP;
              else if (st == S_LOOP) begin
                cur <= cur + 1'b1;
                if (cur == 11'(NC - 1)) st <= S_EXT;
              end else st <= S_DRAIN;
            end else slot <= slot + 1'b1;
          end
        end
      endcase
    end
  end
endmodule
