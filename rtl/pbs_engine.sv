// The PBS engine (docs/ARCHITECTURE.md §4.6): LWE ciphertexts under the big key in, bootstrapped
// LWE ciphertexts out, for PARAM_MESSAGE_2_CARRY_2_KS32_PBS_TUNIFORM_2M128.
//   input RAM (2^BSLOG slots x 2049 u64) -> per slot: KS32 + centred MS (ks32) -> ms values into
//   br_core -> blind rotation of all slots -> psi -> 2049 u64 per slot on o_*.
// Keys: the KSK is loaded through ksk_* (ks32 layout), the y-form LUT through lut_*, and the BSK
// is served on request (bsk_req / op_* / bsk_done, see br_core).
// Two batch banks: the host loads a batch into input bank b and pulses start (start_bank = b)
// when bank_free[b]. The key switch of one bank overlaps the blind rotation of the other; the
// blind rotation takes key-switched banks in start order. done pulses (done_bank) with the last
// output word of a batch; outputs carry o_bank. A bank is free again once its blind rotation ends.
module pbs_engine #(
  parameter int    RED    = ntt_pkg::RED_MONT,
  parameter int    RED_F  = RED,
  parameter int    RED_M  = RED,
  parameter int    RED_I  = RED,
  parameter int    PLOG   = 5,
  parameter int    BSLOG  = 3,
  parameter int    NC     = 918,
  parameter int    KSL    = 256,
  parameter string ROMDIR = "",
  parameter string ROMDIR_F = ROMDIR,
  parameter string ROMDIR_I = ROMDIR
) (
  input  logic                           clk,
  input  logic                           rst,
  input  logic                           ksk_we,
  input  logic [$clog2(2048*4*((NC+KSL)/KSL))-1:0] ksk_addr,
  input  logic [KSL*32-1:0]              ksk_wdata,
  input  logic                           lut_we,
  input  logic [1:0]                     lut_res,
  input  logic [ntt_pkg::LOG_N-PLOG-1:0] lut_addr,
  input  logic [(1<<PLOG)*18-1:0]        lut_wdata,
  input  logic                           in_we,
  input  logic                           in_bank,
  input  logic [BSLOG-1:0]               in_slot,
  input  logic [11:0]                    in_addr,
  input  logic [63:0]                    in_wdata,
  input  logic                           start,
  input  logic                           start_bank,
  output logic [1:0]                     bank_free,
  output logic                           busy,
  output logic                           done,
  output logic                           done_bank,
  output logic                           bsk_req,
  output logic [10:0]                    bsk_req_idx,
  output logic                           bsk_req_buf,
  input  logic                           op_we,
  input  logic                           op_buf,
  input  logic [ntt_pkg::LOG_N-PLOG-1:0] op_addr,
  input  logic [3*4*(1<<PLOG)*18-1:0]    op_wdata,
  input  logic                           bsk_done,
  output logic                           o_valid,
  output logic                           o_bank,
  output logic [BSLOG-1:0]               o_slot,
  output logic [11:0]                    o_idx,
  output logic [63:0]                    o_data
);
  localparam int BS = 1 << BSLOG;

  // ---- input ciphertexts
  // ~116 BRAM36: the read address is registered and so is the output (read latency 3 from
  // in_raddr), so neither the address fanout nor the cascade output shares a cycle with logic
  // cascade_height: build 010 chained 7 BRAMs from the read register to in_q (9 levels at 250 MHz)
  (* cascade_height = 1 *) logic [63:0] inram [2 * BS * 4096];
  logic [63:0] in_r, in_q;
  logic [BSLOG+12:0] in_raddr;
  (* max_fanout = 16 *) logic [BSLOG+12:0] in_ra_q;
  always_ff @(posedge clk) begin
    if (in_we) inram[{in_bank, in_slot, in_addr}] <= in_wdata;
    in_ra_q <= in_raddr;
    in_r <= inram[in_ra_q];
    in_q <= in_r;
  end

  // ---- key switch, one slot at a time
  logic        k_ct_we, k_start, k_busy, k_ksv, k_msv;
  logic [11:0] k_ct_addr;
  logic [9:0]  k_ksi, k_msi;
  logic [31:0] k_ksval;
  logic [11:0] k_msval;
  ks32 #(.NOUT(NC), .L(KSL)) u_ks (
    .clk(clk), .rst(rst), .ksk_we(ksk_we), .ksk_addr(ksk_addr), .ksk_wdata(ksk_wdata),
    .ct_we(k_ct_we), .ct_addr(k_ct_addr), .ct_wdata(in_q), .start(k_start), .busy(k_busy),
    .ks_valid(k_ksv), .ks_idx(k_ksi), .ks_val(k_ksval), .ms_valid(k_msv), .ms_idx(k_msi), .ms_val(k_msval));
  wire unused_ks = ^{k_ksv, k_ksi, k_ksval};

  // ---- blind rotation + psi
  logic              b_start, b_busy, b_done, ex_valid, ex_sof;
  logic [BSLOG-1:0]  ex_slot, ks_slot;
  logic [3*(1<<PLOG)*18-1:0] ex_d;
  logic [3*18-1:0]   ex_body;
  br_core #(.RED_F(RED_F), .RED_M(RED_M), .RED_I(RED_I), .PLOG(PLOG), .BSLOG(BSLOG), .NC(NC),
            .ROMDIR_F(ROMDIR_F), .ROMDIR_I(ROMDIR_I)) u_br (
    .clk(clk), .rst(rst), .lut_we(lut_we), .lut_res(lut_res), .lut_addr(lut_addr), .lut_wdata(lut_wdata),
    .ms_we(k_msv), .ms_bank(ks_bank), .ms_slot(ks_slot), .ms_idx(k_msi), .ms_val(k_msval),
    .start(b_start), .start_bank(br_bank), .busy(b_busy), .done(b_done),
    .bsk_req(bsk_req), .bsk_req_idx(bsk_req_idx), .bsk_req_buf(bsk_req_buf), .op_we(op_we), .op_buf(op_buf),
    .op_addr(op_addr), .op_wdata(op_wdata), .bsk_done(bsk_done),
    .ex_valid(ex_valid), .ex_sof(ex_sof), .ex_slot(ex_slot), .ex_d(ex_d), .ex_body(ex_body));
  psi_unit #(.PLOG(PLOG), .BSLOG(BSLOG)) u_psi (
    .clk(clk), .rst(rst), .ex_valid(ex_valid), .ex_sof(ex_sof), .ex_slot(ex_slot), .ex_d(ex_d), .ex_body(ex_body),
    .o_valid(o_valid), .o_slot(o_slot), .o_idx(o_idx), .o_data(o_data));
  wire unused_bbusy = b_busy;

  // ---- bank states: FREE -> KS (keyswitching) -> KSD (waiting for the blind rotation) -> BR
  typedef enum logic [1:0] {B_FREE, B_KS, B_KSD, B_BR} bst_e;
  bst_e bstate [2];
  // key-switched banks in completion order (2-entry FIFO): push at KS end, pop at BR start
  logic kq [2];
  logic kq_head;
  logic [1:0] kq_cnt;
  logic kq_push, kq_pop;
  assign bank_free[0] = (bstate[0] == B_FREE);
  assign bank_free[1] = (bstate[1] == B_FREE);
  assign busy = (bstate[0] != B_FREE) || (bstate[1] != B_FREE) || psi_busy;

  // ---- KS process: copy slot -> KS -> next slot, for one bank at a time (start order)
  typedef enum logic [2:0] {E_IDLE, E_COPY, E_KS, E_WAIT} kst_e;
  kst_e        kst;
  logic        ks_bank;
  logic        pend_v [2];               // start requests not yet keyswitched (start order)
  logic        pend_b [2];
  logic [11:0] cp;
  logic        cp_v [3];
  logic [11:0] cp_a [3];
  assign in_raddr = {ks_bank, ks_slot, cp};
  // the RAM word read with address cp arrives three cycles later, together with cp_v / cp_a[2]
  assign k_ct_we   = cp_v[2];
  assign k_ct_addr = cp_a[2];
  always_ff @(posedge clk) begin
    cp_v[1] <= cp_v[0] && !rst; cp_v[2] <= cp_v[1] && !rst;
    cp_a[1] <= cp_a[0];         cp_a[2] <= cp_a[1];
  end

  // ---- BR process
  logic        br_on, br_bank, psi_busy, psi_bank;
  assign kq_push = (kst == E_WAIT) && !k_start && !k_busy && !k_msv && (ks_slot == BSLOG'(BS - 1));
  assign kq_pop  = !br_on && (kq_cnt != 0);   // psi drains (~16k cyc) long before the next EXTRACT
  logic [31:0] outs;
  assign o_bank = psi_bank;

  always_ff @(posedge clk) begin
    k_start <= 1'b0;
    b_start <= 1'b0;
    done <= 1'b0;
    if (rst) begin
      kst <= E_IDLE; cp_v[0] <= 1'b0; br_on <= 1'b0; psi_busy <= 1'b0;
      bstate[0] <= B_FREE; bstate[1] <= B_FREE;
      pend_v[0] <= 1'b0; pend_v[1] <= 1'b0; kq_cnt <= '0; kq_head <= 1'b0; outs <= '0;
    end else begin
      cp_v[0] <= 1'b0;
      // host start: queue the bank for keyswitching
      if (start && bstate[start_bank] == B_FREE) begin
        bstate[start_bank] <= B_KS;
        if (!pend_v[0]) begin pend_v[0] <= 1'b1; pend_b[0] <= start_bank; end
        else begin pend_v[1] <= 1'b1; pend_b[1] <= start_bank; end
      end
      // KS process
      case (kst)
        E_IDLE: if (pend_v[0]) begin
          kst <= E_COPY; ks_bank <= pend_b[0]; ks_slot <= '0; cp <= '0;
          pend_v[0] <= pend_v[1]; pend_b[0] <= pend_b[1]; pend_v[1] <= 1'b0;
        end
        E_COPY: begin                       // read address cp now, data 3 cycles later
          cp_v[0] <= 1'b1;
          cp_a[0] <= cp;
          if (cp == 12'd2048) kst <= E_KS; else cp <= cp + 1'b1;
        end
        E_KS: if (!cp_v[0] && !cp_v[1] && !cp_v[2]) begin k_start <= 1'b1; kst <= E_WAIT; end
        E_WAIT: if (!k_start && !k_busy && !k_msv) begin
          if (ks_slot == BSLOG'(BS - 1)) begin
            kst <= E_IDLE;
            bstate[ks_bank] <= B_KSD;
            kq[kq_head ^ kq_cnt[0]] <= ks_bank;
          end else begin ks_slot <= ks_slot + 1'b1; cp <= '0; kst <= E_COPY; end
        end
        default: kst <= E_IDLE;
      endcase
      // BR process: start the oldest key-switched bank when the core and psi are free
      if (kq_pop) begin
        br_on <= 1'b1;
        br_bank <= kq[kq_head];
        b_start <= 1'b1;
        bstate[kq[kq_head]] <= B_BR;
        kq_head <= ~kq_head;
      end
      kq_cnt <= kq_cnt + 2'(kq_push) - 2'(kq_pop);
      if (b_done) begin
        br_on <= 1'b0;
        bstate[br_bank] <= B_FREE;          // ms values no longer needed
      end
      // psi emits a slot as soon as its EXTRACT frame is complete, i.e. before b_done: the output
      // bank is latched at the batch's first EXTRACT frame (the previous batch's psi output ended
      // ~470k cycles earlier) and the words are counted from there.
      if (ex_valid && ex_sof && ex_slot == '0) begin
        psi_busy <= 1'b1;
        psi_bank <= br_bank;
      end
      if (o_valid) begin
        if (outs == 32'(BS * 2049 - 1)) begin
          outs <= '0;
          psi_busy <= 1'b0;
          done <= 1'b1;
          done_bank <= psi_bank;
        end else outs <= outs + 1;
      end
    end
  end
endmodule
