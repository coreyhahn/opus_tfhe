# opus_tfhe Verilator testbenches. Run ON SNOKE:
#   make -C tb <target> JOBS=24
# Every testbench/variant has its own obj_dir (never share one between hosts or processes).
RTL      := ../rtl
JOBS     ?= 24
SEEDS    ?= 1 2 3 4
EVID     ?= ../evidence/stage1
VFLAGS   := --binary --timing -Wno-fatal -Wno-BLKSEQ -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM --unroll-count 4096 \
            --build-jobs $(JOBS) --verilate-jobs 1 -O3 --x-assign fast --x-initial fast -I$(RTL)
PKG      := $(RTL)/ntt_pkg.sv
VLIB     ?= ../verilator_lib   # Verilator models of the Xilinx primitives (DSP48E2, XPM); set VLIB
XLIB     := $(VLIB)/verilator_xilinx.vlt $(VLIB)/primitives/glbl.sv $(VLIB)/xpm/xpm_cdc.sv $(VLIB)/xpm/xpm_memory.sv $(VLIB)/xpm/xpm_fifo.sv
ENG_RTL  := $(RTL)/modmul.sv $(RTL)/bfly.sv $(RTL)/ntt_pipe_stage.sv $(RTL)/ntt_pipe.sv $(RTL)/xpipe1.sv $(RTL)/xpipe3.sv \
            $(RTL)/digit_unit.sv $(RTL)/acc_slice.sv $(RTL)/br_core.sv $(RTL)/psi_unit.sv $(RTL)/ksk_ram.sv $(RTL)/ks_lanes.sv $(RTL)/ks32.sv $(RTL)/pbs_engine.sv
TOP_RTL  := $(ENG_RTL) $(RTL)/ddr_rd_streamer.sv $(RTL)/ddr_chan_rd.sv $(RTL)/bsk_lane.sv $(RTL)/bsk_asm.sv $(RTL)/ksk_slice.sv $(RTL)/ksk_asm.sv $(RTL)/out_ram.sv \
            $(RTL)/io_win.sv $(RTL)/opus_csr.sv $(RTL)/opus_top.sv

.PHONY: lint modmul

lint_top:
	verilator --lint-only -Wall --unroll-count 4096 -Wno-UNUSEDPARAM -I$(RTL) lint_xpm.vlt $(XLIB) $(PKG) $(TOP_RTL) --top-module opus_top

lint_top_flat:
	verilator --lint-only -Wall --unroll-count 4096 -Wno-UNUSEDPARAM -I$(RTL) lint_xpm.vlt $(XLIB) $(PKG) $(TOP_RTL) $(RTL)/opus_top_flat.sv --top-module opus_top_flat

lint:
	verilator --lint-only -Wall --unroll-count 4096 -Wno-UNUSEDPARAM -I$(RTL) $(PKG) $(RTL)/modmul.sv --top-module modmul
	verilator --lint-only -Wall --unroll-count 4096 -I$(RTL) $(RTL)/digit_unit.sv --top-module digit_unit
	verilator --lint-only -Wall --unroll-count 4096 -Wno-UNUSEDPARAM -I$(RTL) $(PKG) $(RTL)/acc_slice.sv --top-module acc_slice
	verilator --lint-only -Wall --unroll-count 4096 -Wno-UNUSEDPARAM -I$(RTL) $(PKG) $(RTL)/modmul.sv $(RTL)/bfly.sv $(RTL)/ntt_pipe_stage.sv $(RTL)/ntt_pipe.sv $(RTL)/xpipe1.sv $(RTL)/xpipe3.sv $(RTL)/digit_unit.sv $(RTL)/acc_slice.sv $(RTL)/br_core.sv --top-module br_core
	verilator --lint-only -Wall --unroll-count 4096 -Wno-UNUSEDPARAM -I$(RTL) $(PKG) $(RTL)/psi_unit.sv --top-module psi_unit
	verilator --lint-only -Wall --unroll-count 4096 -I$(RTL) $(RTL)/ksk_ram.sv $(RTL)/ks_lanes.sv $(RTL)/ks32.sv --top-module ks32
	verilator --lint-only -Wall --unroll-count 4096 -Wno-UNUSEDPARAM -I$(RTL) $(PKG) $(RTL)/modmul.sv $(RTL)/bfly.sv $(RTL)/ntt_pipe_stage.sv $(RTL)/ntt_pipe.sv $(RTL)/xpipe1.sv $(RTL)/xpipe3.sv $(RTL)/digit_unit.sv $(RTL)/acc_slice.sv $(RTL)/br_core.sv $(RTL)/psi_unit.sv $(RTL)/ksk_ram.sv $(RTL)/ks_lanes.sv $(RTL)/ks32.sv $(RTL)/pbs_engine.sv --top-module pbs_engine
	verilator --lint-only -Wall --unroll-count 4096 -Wno-UNUSEDPARAM -I$(RTL) lint_xpm.vlt $(XLIB) $(PKG) $(TOP_RTL) --top-module opus_top
	verilator --lint-only -Wall --unroll-count 4096 -Wno-UNUSEDPARAM -I$(RTL) lint_xpm.vlt $(XLIB) $(PKG) $(TOP_RTL) $(RTL)/opus_top_flat.sv --top-module opus_top_flat
	verilator --lint-only -Wall --unroll-count 4096 -Wno-UNUSEDPARAM -I$(RTL) $(PKG) $(RTL)/modmul.sv $(RTL)/bfly.sv $(RTL)/sfifo.sv $(RTL)/ntt_cg.sv --top-module ntt_cg -GROM_FILE='""'
	verilator --lint-only -Wall --unroll-count 4096 -Wno-UNUSEDPARAM -I$(RTL) $(PKG) $(RTL)/modmul.sv $(RTL)/bfly.sv $(RTL)/sfifo.sv $(RTL)/ntt_cg.sv $(RTL)/extprod1.sv $(RTL)/extprod3.sv --top-module extprod3
	verilator --lint-only -Wall --unroll-count 4096 -Wno-UNUSEDPARAM -I$(RTL) $(PKG) $(RTL)/modmul.sv $(RTL)/bfly.sv $(RTL)/ntt_pipe_stage.sv $(RTL)/ntt_pipe.sv --top-module ntt_pipe
	verilator --lint-only -Wall --unroll-count 4096 -Wno-UNUSEDPARAM -I$(RTL) $(PKG) $(RTL)/modmul.sv $(RTL)/bfly.sv $(RTL)/ntt_pipe_stage.sv $(RTL)/ntt_pipe.sv $(RTL)/xpipe1.sv $(RTL)/xpipe3.sv --top-module xpipe3

obj_dir_modmul/Vtb_modmul: $(PKG) $(RTL)/modmul.sv tb_modmul.sv
	verilator $(VFLAGS) --Mdir obj_dir_modmul --top-module tb_modmul $^

modmul: obj_dir_modmul/Vtb_modmul
	@mkdir -p $(EVID)
	@for s in $(SEEDS); do ( echo "$$ obj_dir_modmul/Vtb_modmul +seed=$$s"; echo "# host $$(hostname) date $$(date -Iseconds) git $$(git rev-parse --short HEAD)"; \
	  obj_dir_modmul/Vtb_modmul +seed=$$s ) > $(EVID)/tb_modmul_s$$s.log 2>&1 & done; wait; \
	  grep -h "PASS\|FAILED\|ERROR" $(EVID)/tb_modmul_s*.log; ! grep -q "FAILED\|ERROR\|%Error" $(EVID)/tb_modmul_s*.log; \
	  for f in $(EVID)/tb_modmul_s*.log; do grep -q "^PASS" $$f || { echo "NO PASS in $$f"; exit 1; }; done

# ---- NTT core: make ntt T=8 M=1 RED=0  (RED 0 = MONT, 1 = TABLE)
T   ?= 8
M   ?= 1
RED ?= 0
REDN := $(if $(filter 1,$(RED)),table,mont)
VECROOT := $(abspath vec)
DUMP := ../ref/tfhe_model/target/release/dump_ntt
NTT_OBJ := obj_dir_ntt_T$(T)_M$(M)_$(REDN)
NTT_SRCS := $(PKG) $(RTL)/modmul.sv $(RTL)/bfly.sv $(RTL)/sfifo.sv $(RTL)/ntt_cg.sv tb_ntt.sv

.PHONY: ntt vec_ntt
vec_ntt:
	@for s in $(SEEDS); do $(DUMP) --t $(T) --red $(REDN) --seed $$s --jobs 6 --out $(VECROOT)/T$(T)_$(REDN)_s$$s > /dev/null; done

$(NTT_OBJ)/Vtb_ntt: $(NTT_SRCS) | vec_ntt
	verilator $(VFLAGS) --Mdir $(NTT_OBJ) --top-module tb_ntt -GT=$(T) -GM=$(M) -GRED=$(RED) \
	  -GROMDIR='"$(VECROOT)/T$(T)_$(REDN)_s1"' $(NTT_SRCS)

ntt: vec_ntt $(NTT_OBJ)/Vtb_ntt
	@mkdir -p $(EVID)
	@for s in $(SEEDS); do ( echo "$$ $(NTT_OBJ)/Vtb_ntt +vec=$(VECROOT)/T$(T)_$(REDN)_s$$s +jobs=6 +seed=$$s +gap=10"; \
	  echo "# host $$(hostname) date $$(date -Iseconds) git $$(git rev-parse --short HEAD)"; \
	  $(NTT_OBJ)/Vtb_ntt +vec=$(VECROOT)/T$(T)_$(REDN)_s$$s +jobs=6 +seed=$$s +gap=10 ) > $(EVID)/tb_ntt_T$(T)_M$(M)_$(REDN)_s$$s.log 2>&1 & done; wait; \
	  grep -h "PASS\|FAILED\|ERROR\|steady" $(EVID)/tb_ntt_T$(T)_M$(M)_$(REDN)_s*.log | sort | uniq | head -40; \
	  ! grep -q "FAILED\|ERROR\|%Error" $(EVID)/tb_ntt_T$(T)_M$(M)_$(REDN)_s*.log; \
	  for f in $(EVID)/tb_ntt_T$(T)_M$(M)_$(REDN)_s*.log; do grep -q "^PASS" $$f || { echo "NO PASS in $$f"; exit 1; }; done

# ---- external product (3 residues): make extprod T=8 M=1 RED=0
XP_OBJ  := obj_dir_xp_T$(T)_M$(M)_$(REDN)
XP_SRCS := $(PKG) $(RTL)/modmul.sv $(RTL)/bfly.sv $(RTL)/sfifo.sv $(RTL)/ntt_cg.sv $(RTL)/extprod1.sv $(RTL)/extprod3.sv tb_extprod.sv
.PHONY: extprod
$(XP_OBJ)/Vtb_extprod: $(XP_SRCS) | vec_ntt
	verilator $(VFLAGS) --Mdir $(XP_OBJ) --top-module tb_extprod -GT=$(T) -GM=$(M) -GRED=$(RED) \
	  -GROMDIR='"$(VECROOT)/T$(T)_$(REDN)_s1"' $(XP_SRCS)

extprod: vec_ntt $(XP_OBJ)/Vtb_extprod
	@mkdir -p $(EVID)
	@for s in $(SEEDS); do ( echo "$$ $(XP_OBJ)/Vtb_extprod +vec=$(VECROOT)/T$(T)_$(REDN)_s$$s +jobs=6 +seed=$$s +gap=10"; \
	  echo "# host $$(hostname) date $$(date -Iseconds) git $$(git rev-parse --short HEAD)"; \
	  $(XP_OBJ)/Vtb_extprod +vec=$(VECROOT)/T$(T)_$(REDN)_s$$s +jobs=6 +seed=$$s +gap=10 ) > $(EVID)/tb_extprod_T$(T)_M$(M)_$(REDN)_s$$s.log 2>&1 & done; wait; \
	  grep -h "PASS\|FAILED\|ERROR\|group\|%Error" $(EVID)/tb_extprod_T$(T)_M$(M)_$(REDN)_s*.log | sort | uniq -c | head -20; \
	  ! grep -q "FAILED\|ERROR\|%Error" $(EVID)/tb_extprod_T$(T)_M$(M)_$(REDN)_s*.log; \
	  for f in $(EVID)/tb_extprod_T$(T)_M$(M)_$(REDN)_s*.log; do grep -q "^PASS" $$f || { echo "NO PASS in $$f"; exit 1; }; done

# ---- streaming NTT pipeline: make pipe PLOG=4 RED=0
PLOG ?= 4
PRIME ?= 249857
DUMPP := ../ref/tfhe_model/target/release/dump_pipe
PIPE_OBJ  := obj_dir_pipe_P$(PLOG)_$(REDN)
PIPE_SRCS := $(PKG) $(RTL)/modmul.sv $(RTL)/bfly.sv $(RTL)/ntt_pipe_stage.sv $(RTL)/ntt_pipe.sv tb_pipe.sv
.PHONY: pipe vec_pipe
vec_pipe:
	@for s in $(SEEDS); do $(DUMPP) --plog $(PLOG) --red $(REDN) --seed $$s --jobs 6 --out $(VECROOT)/P$(PLOG)_$(REDN)_s$$s > /dev/null; done

$(PIPE_OBJ)/Vtb_pipe: $(PIPE_SRCS) | vec_pipe
	verilator $(VFLAGS) --Mdir $(PIPE_OBJ) --top-module tb_pipe -GPLOG=$(PLOG) -GRED=$(RED) \
	  -GROMDIR='"$(VECROOT)/P$(PLOG)_$(REDN)_s1"' $(PIPE_SRCS)

pipe: vec_pipe $(PIPE_OBJ)/Vtb_pipe
	@mkdir -p $(EVID)
	@for s in $(SEEDS); do ( echo "$$ $(PIPE_OBJ)/Vtb_pipe +vec=$(VECROOT)/P$(PLOG)_$(REDN)_s$$s +jobs=6 +seed=$$s +gap=3"; \
	  echo "# host $$(hostname) date $$(date -Iseconds) git $$(git rev-parse --short HEAD)"; \
	  $(PIPE_OBJ)/Vtb_pipe +vec=$(VECROOT)/P$(PLOG)_$(REDN)_s$$s +jobs=6 +seed=$$s +gap=3 ) > $(EVID)/tb_pipe_P$(PLOG)_$(REDN)_s$$s.log 2>&1 & done; wait; \
	  grep -h "PASS\|FAILED\|ERROR\|latency" $(EVID)/tb_pipe_P$(PLOG)_$(REDN)_s*.log | sort | uniq -c | head -20; \
	  ! grep -q "FAILED\|ERROR\|%Error" $(EVID)/tb_pipe_P$(PLOG)_$(REDN)_s*.log; \
	  for f in $(EVID)/tb_pipe_P$(PLOG)_$(REDN)_s*.log; do grep -q "^PASS" $$f || { echo "NO PASS in $$f"; exit 1; }; done

# ---- streaming external product (3 residues): make xpipe PLOG=4 RED=0
XPP_OBJ  := obj_dir_xpipe_P$(PLOG)_$(REDN)
XPP_SRCS := $(PKG) $(RTL)/modmul.sv $(RTL)/bfly.sv $(RTL)/ntt_pipe_stage.sv $(RTL)/ntt_pipe.sv $(RTL)/xpipe1.sv $(RTL)/xpipe3.sv tb_xpipe.sv
.PHONY: xpipe
$(XPP_OBJ)/Vtb_xpipe: $(XPP_SRCS) | vec_pipe
	verilator $(VFLAGS) --Mdir $(XPP_OBJ) --top-module tb_xpipe -GPLOG=$(PLOG) -GRED=$(RED) \
	  -GROMDIR='"$(VECROOT)/P$(PLOG)_$(REDN)_s1"' $(XPP_SRCS)

xpipe: vec_pipe $(XPP_OBJ)/Vtb_xpipe
	@mkdir -p $(EVID)
	@for s in $(SEEDS); do ( echo "$$ $(XPP_OBJ)/Vtb_xpipe +vec=$(VECROOT)/P$(PLOG)_$(REDN)_s$$s +jobs=6 +seed=$$s +gap=3"; \
	  echo "# host $$(hostname) date $$(date -Iseconds) git $$(git rev-parse --short HEAD)"; \
	  $(XPP_OBJ)/Vtb_xpipe +vec=$(VECROOT)/P$(PLOG)_$(REDN)_s$$s +jobs=6 +seed=$$s +gap=3 ) > $(EVID)/tb_xpipe_P$(PLOG)_$(REDN)_s$$s.log 2>&1 & done; wait; \
	  grep -h "PASS\|FAILED\|ERROR\|latency" $(EVID)/tb_xpipe_P$(PLOG)_$(REDN)_s*.log | sort | uniq -c | head -20; \
	  ! grep -q "FAILED\|ERROR\|%Error" $(EVID)/tb_xpipe_P$(PLOG)_$(REDN)_s*.log; \
	  for f in $(EVID)/tb_xpipe_P$(PLOG)_$(REDN)_s*.log; do grep -q "^PASS" $$f || { echo "NO PASS in $$f"; exit 1; }; done

# ---- Stage 2 blocks
DUMPE := ../ref/tfhe_model/target/release/dump_engine
EVID2 ?= ../evidence/stage2
EVID3 ?= ../evidence/stage3
.PHONY: digit
obj_dir_digit/Vtb_digit: $(RTL)/digit_unit.sv tb_digit.sv
	verilator $(VFLAGS) --Mdir obj_dir_digit --top-module tb_digit -GLANES=4 $^

digit: obj_dir_digit/Vtb_digit
	@mkdir -p $(EVID2) $(VECROOT)
	@for s in $(SEEDS); do $(DUMPE) digits --count 200000 --seed $$s --out $(VECROOT)/digits_s$$s.txt > /dev/null; \
	  ( echo "$$ obj_dir_digit/Vtb_digit +vec=$(VECROOT)/digits_s$$s.txt"; echo "# host $$(hostname) date $$(date -Iseconds) git $$(git rev-parse --short HEAD)"; \
	  obj_dir_digit/Vtb_digit +vec=$(VECROOT)/digits_s$$s.txt ) > $(EVID2)/tb_digit_s$$s.log 2>&1 & done; wait; \
	  grep -h "PASS\|FAILED\|ERROR" $(EVID2)/tb_digit_s*.log | head; ! grep -q "FAILED\|ERROR\|%Error" $(EVID2)/tb_digit_s*.log; \
	  for f in $(EVID2)/tb_digit_s*.log; do grep -q "^PASS" $$f || { echo "NO PASS in $$f"; exit 1; }; done

# ---- accumulator slice: make slice PLOG=5
SLICE_SRCS := $(PKG) $(RTL)/acc_slice.sv tb_slice.sv
.PHONY: slice
obj_dir_slice_P$(PLOG)_$(PRIME)/Vtb_slice: $(SLICE_SRCS)
	verilator $(VFLAGS) --Mdir obj_dir_slice_P$(PLOG)_$(PRIME) --top-module tb_slice -GPLOG=$(PLOG) -GBSLOG=2 -GPRIME=$(PRIME) $(SLICE_SRCS)

slice: obj_dir_slice_P$(PLOG)_$(PRIME)/Vtb_slice
	@mkdir -p $(EVID2) $(VECROOT)
	@for s in $(SEEDS); do $(DUMPE) slice --plog $(PLOG) --prime $(PRIME) --slots 4 --ops 40 --seed $$s --out $(VECROOT)/slice_P$(PLOG)_$(PRIME)_s$$s > /dev/null; \
	  ( echo "$$ obj_dir_slice_P$(PLOG)_$(PRIME)/Vtb_slice +vec=$(VECROOT)/slice_P$(PLOG)_$(PRIME)_s$$s"; echo "# host $$(hostname) date $$(date -Iseconds) git $$(git rev-parse --short HEAD)"; \
	  obj_dir_slice_P$(PLOG)_$(PRIME)/Vtb_slice +vec=$(VECROOT)/slice_P$(PLOG)_$(PRIME)_s$$s ) > $(EVID2)/tb_slice_P$(PLOG)_$(PRIME)_s$$s.log 2>&1 & done; wait; \
	  grep -h "PASS\|FAILED\|ERROR" $(EVID2)/tb_slice_P$(PLOG)_$(PRIME)_s*.log | head; ! grep -q "FAILED\|ERROR\|%Error" $(EVID2)/tb_slice_P$(PLOG)_$(PRIME)_s*.log; \
	  for f in $(EVID2)/tb_slice_P$(PLOG)_$(PRIME)_s*.log; do grep -q "^PASS" $$f || { echo "NO PASS in $$f"; exit 1; }; done

# ---- blind-rotation core: make br PLOG=5 NC=8  (ROMs from dump_pipe, MONT)
NC ?= 8
BR_SRCS := $(PKG) $(RTL)/modmul.sv $(RTL)/bfly.sv $(RTL)/ntt_pipe_stage.sv $(RTL)/ntt_pipe.sv $(RTL)/xpipe1.sv $(RTL)/xpipe3.sv \
           $(RTL)/digit_unit.sv $(RTL)/acc_slice.sv $(RTL)/br_core.sv $(RTL)/psi_unit.sv tb_br.sv
BR_OBJ := obj_dir_br_P$(PLOG)_N$(NC)
.PHONY: br brwrap
$(BR_OBJ)/Vtb_br: $(BR_SRCS)
	@$(DUMPP) --plog $(PLOG) --red mont --jobs 3 --out $(VECROOT)/P$(PLOG)_mont_br > /dev/null
	verilator $(VFLAGS) --Mdir $(BR_OBJ) --top-module tb_br -GPLOG=$(PLOG) -GBSLOG=3 -GNC=$(NC) \
	  -GROMDIR='"$(VECROOT)/P$(PLOG)_mont_br"' $(BR_SRCS)

br: $(BR_OBJ)/Vtb_br
	@mkdir -p $(EVID2)
	@for s in $(SEEDS); do $(DUMPE) br --plog $(PLOG) --slots 8 --n $(NC) --seed $$s --out $(VECROOT)/br_P$(PLOG)_N$(NC)_s$$s > /dev/null; \
	  ( echo "$$ $(BR_OBJ)/Vtb_br +vec=$(VECROOT)/br_P$(PLOG)_N$(NC)_s$$s"; echo "# host $$(hostname) date $$(date -Iseconds) git $$(git rev-parse --short HEAD)"; \
	  $(BR_OBJ)/Vtb_br +vec=$(VECROOT)/br_P$(PLOG)_N$(NC)_s$$s ) > $(EVID2)/tb_br_P$(PLOG)_N$(NC)_s$$s.log 2>&1 & done; wait; \
	  grep -h "PASS\|FAILED\|ERROR\|br_core:" $(EVID2)/tb_br_P$(PLOG)_N$(NC)_s*.log | head -12; \
	  for f in $(EVID2)/tb_br_P$(PLOG)_N$(NC)_s*.log; do grep -q "^PASS" $$f || { echo "NO PASS in $$f"; exit 1; }; done

# ---- br_core with its frame-schedule counter starting 3000 cycles before the 32-bit wrap, so the
#      wrap lands mid-batch (silicon stalled 2^32 cycles there, 2026-11-03): make brwrap PLOG=5 NC=8
BRW_OBJ := obj_dir_brwrap_P$(PLOG)_N$(NC)_$(shell hostname)
$(BRW_OBJ)/Vtb_br: $(BR_SRCS)
	@$(DUMPP) --plog $(PLOG) --red mont --jobs 3 --out $(VECROOT)/P$(PLOG)_mont_br > /dev/null
	verilator $(VFLAGS) --Mdir $(BRW_OBJ) --top-module tb_br -GPLOG=$(PLOG) -GBSLOG=3 -GNC=$(NC) \
	  -GCYC_RST=32\'hFFFFF448 -GROMDIR='"$(VECROOT)/P$(PLOG)_mont_br"' $(BR_SRCS)

brwrap: $(BRW_OBJ)/Vtb_br
	@mkdir -p $(EVID3)/brwrap
	@$(DUMPE) br --plog $(PLOG) --slots 8 --n $(NC) --seed 1 --out $(VECROOT)/brw_P$(PLOG)_N$(NC)_s1 > /dev/null
	@for d in $$(seq 0 63); do \
	  ( echo "$$ $(BRW_OBJ)/Vtb_br +vec=$(VECROOT)/brw_P$(PLOG)_N$(NC)_s1 +maxcyc=1000000 +predelay=$$d"; echo "# host $$(hostname) date $$(date -Iseconds) git $$(git rev-parse --short HEAD)"; \
	  $(BRW_OBJ)/Vtb_br +vec=$(VECROOT)/brw_P$(PLOG)_N$(NC)_s1 +maxcyc=1000000 +predelay=$$d ) > $(EVID3)/brwrap/tb_brwrap_P$(PLOG)_N$(NC)_d$$d.log 2>&1 & \
	  if [ $$((d % 16)) -eq 15 ]; then wait; fi; done; wait; \
	  echo "PASS: $$(grep -l '^PASS' $(EVID3)/brwrap/tb_brwrap_P$(PLOG)_N$(NC)_d*.log | wc -l) / 64 phases"; \
	  grep -h "FAILED\|ERROR\|timeout" $(EVID3)/brwrap/tb_brwrap_P$(PLOG)_N$(NC)_d*.log | sort | uniq -c | head; \
	  for f in $(EVID3)/brwrap/tb_brwrap_P$(PLOG)_N$(NC)_d*.log; do grep -q "^PASS" $$f || { echo "NO PASS in $$f"; exit 1; }; done

# ---- real tfhe-rs keys through br_core + psi, n = 918, outputs decrypted by tfhe-rs:
#      make real PLOG=5   (keys: ../data/v28/ks32_s<seed>, cts 0..7; the oracle binary from ref/tfhe_oracle)
ORACLE := ../ref/tfhe_oracle/target/release/tfhe_oracle
REAL_OBJ := obj_dir_br_P$(PLOG)_N918
.PHONY: real
$(REAL_OBJ)/Vtb_br: $(BR_SRCS)
	@$(DUMPP) --plog $(PLOG) --red mont --jobs 3 --out $(VECROOT)/P$(PLOG)_mont_br > /dev/null
	verilator $(VFLAGS) --Mdir $(REAL_OBJ) --top-module tb_br -GPLOG=$(PLOG) -GBSLOG=3 -GNC=918 \
	  -GROMDIR='"$(VECROOT)/P$(PLOG)_mont_br"' $(BR_SRCS)

real: $(REAL_OBJ)/Vtb_br
	@mkdir -p $(EVID2)
	@for s in $(SEEDS); do ( K=../data/v28/ks32_s$$s; V=$(VECROOT)/real_P$(PLOG)_s$$s; L=$(EVID2)/real_P$(PLOG)_s$$s.log; \
	  echo "# host $$(hostname) date $$(date -Iseconds) git $$(git rev-parse --short HEAD)" > $$L; \
	  echo "$$ dump_engine real --keys $$K --plog $(PLOG) --slots 8 --first 0 --out $$V" >> $$L; \
	  $(DUMPE) real --keys $$K --plog $(PLOG) --slots 8 --first 0 --out $$V >> $$L 2>&1 && \
	  echo "$$ $(REAL_OBJ)/Vtb_br +vec=$$V +outfile=$$V/rtl_out.hex" >> $$L && \
	  $(REAL_OBJ)/Vtb_br +vec=$$V +outfile=$$V/rtl_out.hex >> $$L 2>&1 && \
	  python3 -c "import struct,sys; w=[int(l,16) for l in open(sys.argv[1])]; open(sys.argv[2],'wb').write(struct.pack('<%dQ'%len(w),*w))" $$V/rtl_out.hex $$V/rtl_out.u64 && \
	  echo "$$ tfhe_oracle decrypt --keys $$K --input $$V/rtl_out.u64 --kind pbs" >> $$L && \
	  $(ORACLE) decrypt --keys $$K --input $$V/rtl_out.u64 --kind pbs --json $$V/rtl_dec.json >> $$L 2>&1 && echo "PASS real: RTL PBS outputs decrypted by tfhe-rs" >> $$L ) & done; wait; \
	  grep -h "PASS\|FAILED\|ERROR\|br_core:\|failures\|log2_std" $(EVID2)/real_P$(PLOG)_s*.log | head -24; \
	  for f in $(EVID2)/real_P$(PLOG)_s*.log; do grep -q "^PASS real" $$f || { echo "NO PASS in $$f"; exit 1; }; done

# ---- key switch + centred MS vs tfhe-rs: make ks KSL=16
KSL ?= 16
KS_OBJ := obj_dir_ks_L$(KSL)
.PHONY: ks
$(KS_OBJ)/Vtb_ks: $(RTL)/ksk_ram.sv $(RTL)/ks_lanes.sv $(RTL)/ks32.sv tb_ks.sv
	verilator $(VFLAGS) --Mdir $(KS_OBJ) --top-module tb_ks -GL=$(KSL) $^

ks: $(KS_OBJ)/Vtb_ks
	@mkdir -p $(EVID2)
	@for s in $(SEEDS); do $(DUMPE) ks --keys ../data/v28/ks32_s$$s --lanes $(KSL) --count 4 --out $(VECROOT)/ks_L$(KSL)_s$$s > /dev/null; \
	  ( echo "$$ $(KS_OBJ)/Vtb_ks +vec=$(VECROOT)/ks_L$(KSL)_s$$s +count=4"; echo "# host $$(hostname) date $$(date -Iseconds) git $$(git rev-parse --short HEAD)"; \
	  $(KS_OBJ)/Vtb_ks +vec=$(VECROOT)/ks_L$(KSL)_s$$s +count=4 ) > $(EVID2)/tb_ks_L$(KSL)_s$$s.log 2>&1 & done; wait; \
	  grep -h "PASS\|FAILED\|ERROR" $(EVID2)/tb_ks_L$(KSL)_s*.log | head -12; \
	  for f in $(EVID2)/tb_ks_L$(KSL)_s*.log; do grep -q "^PASS" $$f || { echo "NO PASS in $$f"; exit 1; }; done

# ---- whole PBS engine on real keys, outputs decrypted by tfhe-rs: make pbs PLOG=5 KSL=256
PBS_SRCS := $(BR_SRCS:tb_br.sv=) $(RTL)/ksk_ram.sv $(RTL)/ks_lanes.sv $(RTL)/ks32.sv $(RTL)/pbs_engine.sv tb_pbs.sv
PBS_OBJ := obj_dir_pbs_P$(PLOG)_L$(KSL)_$(shell hostname)
.PHONY: pbs
$(PBS_OBJ)/Vtb_pbs: $(PBS_SRCS)
	@$(DUMPP) --plog $(PLOG) --red mont --jobs 3 --out $(VECROOT)/P$(PLOG)_mont_br > /dev/null
	verilator $(VFLAGS) --Mdir $(PBS_OBJ) --top-module tb_pbs -GPLOG=$(PLOG) -GBSLOG=3 -GKSL=$(KSL) \
	  -GROMDIR='"$(VECROOT)/P$(PLOG)_mont_br"' $(PBS_SRCS)

pbs: $(PBS_OBJ)/Vtb_pbs
	@mkdir -p $(EVID2)
	@for s in $(SEEDS); do ( K=../data/v28/ks32_s$$s; VA=$(VECROOT)/real_P$(PLOG)_s$$s; VB=$(VECROOT)/real_P$(PLOG)_s$${s}_b; KD=$(VECROOT)/ks_L$(KSL)_s$${s}_16; L=$(EVID2)/pbs_P$(PLOG)_L$(KSL)_s$$s.log; \
	  echo "# host $$(hostname) date $$(date -Iseconds) git $$(git rev-parse --short HEAD)" > $$L; \
	  [ -f $$VA/out.hex ] || $(DUMPE) real --keys $$K --plog $(PLOG) --slots 8 --first 0 --out $$VA >> $$L 2>&1; \
	  [ -f $$VB/out.hex ] || $(DUMPE) real --keys $$K --plog $(PLOG) --slots 8 --first 8 --out $$VB >> $$L 2>&1; \
	  $(DUMPE) ks --keys $$K --lanes $(KSL) --count 16 --out $$KD >> $$L 2>&1 && \
	  echo "$$ $(PBS_OBJ)/Vtb_pbs +vecA=$$VA +vecB=$$VB +ks=$$KD +outA=$$VA/pbs_out.hex +outB=$$VB/pbs_out.hex" >> $$L && \
	  $(PBS_OBJ)/Vtb_pbs +vecA=$$VA +vecB=$$VB +ks=$$KD +outA=$$VA/pbs_out.hex +outB=$$VB/pbs_out.hex >> $$L 2>&1 && \
	  python3 -c "import struct,sys; w=[int(l,16) for l in open(sys.argv[1])]+[int(l,16) for l in open(sys.argv[2])]; open(sys.argv[3],'wb').write(struct.pack('<%dQ'%len(w),*w))" $$VA/pbs_out.hex $$VB/pbs_out.hex $$VA/pbs_out16.u64 && \
	  echo "$$ tfhe_oracle decrypt --keys $$K --input $$VA/pbs_out16.u64 --kind pbs" >> $$L && \
	  $(ORACLE) decrypt --keys $$K --input $$VA/pbs_out16.u64 --kind pbs --json $$VA/pbs_dec16.json >> $$L 2>&1 && echo "PASS pbs: 16 engine outputs (lwe_in -> KS -> PBS, two overlapped batches) decrypted by tfhe-rs" >> $$L ) & done; wait; \
	  grep -h "PASS\|FAILED\|ERROR\|pbs_engine:\|\"failures\"\|log2_std" $(EVID2)/pbs_P$(PLOG)_L$(KSL)_s*.log | head -24; \
	  for f in $(EVID2)/pbs_P$(PLOG)_L$(KSL)_s*.log; do grep -q "^PASS pbs" $$f || { echo "NO PASS in $$f"; exit 1; }; done

# ---- blind rotation with mixed reductions (fwd MONT, MAC TABLE, inv TABLE): make brmix PLOG=5 NC=8
BRM_OBJ := obj_dir_brmix_P$(PLOG)_N$(NC)
.PHONY: brmix
$(BRM_OBJ)/Vtb_br: $(BR_SRCS)
	@$(DUMPP) --plog $(PLOG) --red mont --jobs 3 --out $(VECROOT)/P$(PLOG)_mont_br > /dev/null
	@$(DUMPP) --plog $(PLOG) --red table --jobs 3 --out $(VECROOT)/P$(PLOG)_table_br > /dev/null
	verilator $(VFLAGS) --Mdir $(BRM_OBJ) --top-module tb_br -GPLOG=$(PLOG) -GBSLOG=3 -GNC=$(NC) \
	  -GRED_F=0 -GRED_M=1 -GRED_I=1 -GROMDIR_F='"$(VECROOT)/P$(PLOG)_mont_br"' -GROMDIR_I='"$(VECROOT)/P$(PLOG)_table_br"' $(BR_SRCS)

brmix: $(BRM_OBJ)/Vtb_br
	@mkdir -p $(EVID2)
	@for s in $(SEEDS); do $(DUMPE) br --plog $(PLOG) --slots 8 --n $(NC) --red table --seed $$s --out $(VECROOT)/brmix_P$(PLOG)_N$(NC)_s$$s > /dev/null; \
	  ( echo "$$ $(BRM_OBJ)/Vtb_br +vec=$(VECROOT)/brmix_P$(PLOG)_N$(NC)_s$$s"; echo "# host $$(hostname) date $$(date -Iseconds) git $$(git rev-parse --short HEAD)"; \
	  $(BRM_OBJ)/Vtb_br +vec=$(VECROOT)/brmix_P$(PLOG)_N$(NC)_s$$s ) > $(EVID2)/tb_brmix_P$(PLOG)_N$(NC)_s$$s.log 2>&1 & done; wait; \
	  grep -h "PASS\|FAILED\|ERROR\|br_core:" $(EVID2)/tb_brmix_P$(PLOG)_N$(NC)_s*.log | head -12; \
	  for f in $(EVID2)/tb_brmix_P$(PLOG)_N$(NC)_s*.log; do grep -q "^PASS" $$f || { echo "NO PASS in $$f"; exit 1; }; done

# ---- real keys, mixed reductions (fwd MONT, MAC/inv TABLE), n = 918, decrypted by tfhe-rs:
#      make realmix PLOG=5
RMIX_OBJ := obj_dir_realmix_P$(PLOG)_$(shell hostname)
.PHONY: realmix
$(RMIX_OBJ)/Vtb_br: $(BR_SRCS)
	@$(DUMPP) --plog $(PLOG) --red mont --jobs 3 --out $(VECROOT)/P$(PLOG)_mont_br > /dev/null
	@$(DUMPP) --plog $(PLOG) --red table --jobs 3 --out $(VECROOT)/P$(PLOG)_table_br > /dev/null
	verilator $(VFLAGS) --Mdir $(RMIX_OBJ) --top-module tb_br -GPLOG=$(PLOG) -GBSLOG=3 -GNC=918 \
	  -GRED_F=0 -GRED_M=1 -GRED_I=1 -GROMDIR_F='"$(VECROOT)/P$(PLOG)_mont_br"' -GROMDIR_I='"$(VECROOT)/P$(PLOG)_table_br"' $(BR_SRCS)

realmix: $(RMIX_OBJ)/Vtb_br
	@mkdir -p $(EVID2)
	@for s in $(SEEDS); do ( K=../data/v28/ks32_s$$s; V=$(VECROOT)/realmix_P$(PLOG)_s$$s; L=$(EVID2)/realmix_P$(PLOG)_s$$s.log; \
	  echo "# host $$(hostname) date $$(date -Iseconds) git $$(git rev-parse --short HEAD)" > $$L; \
	  $(DUMPE) real --keys $$K --plog $(PLOG) --slots 8 --first 0 --red table --out $$V >> $$L 2>&1 && \
	  echo "$$ $(RMIX_OBJ)/Vtb_br +vec=$$V +outfile=$$V/rtl_out.hex" >> $$L && \
	  $(RMIX_OBJ)/Vtb_br +vec=$$V +outfile=$$V/rtl_out.hex >> $$L 2>&1 && \
	  python3 -c "import struct,sys; w=[int(l,16) for l in open(sys.argv[1])]; open(sys.argv[2],'wb').write(struct.pack('<%dQ'%len(w),*w))" $$V/rtl_out.hex $$V/rtl_out.u64 && \
	  echo "$$ tfhe_oracle decrypt --keys $$K --input $$V/rtl_out.u64 --kind pbs" >> $$L && \
	  $(ORACLE) decrypt --keys $$K --input $$V/rtl_out.u64 --kind pbs --json $$V/rtl_dec.json >> $$L 2>&1 && echo "PASS realmix: RTL PBS outputs (mixed reductions) decrypted by tfhe-rs" >> $$L ) & done; wait; \
	  grep -h "PASS\|FAILED\|ERROR\|br_core:\|\"failures\"\|log2_std" $(EVID2)/realmix_P$(PLOG)_s*.log | head -24; \
	  for f in $(EVID2)/realmix_P$(PLOG)_s*.log; do grep -q "^PASS realmix" $$f || { echo "NO PASS in $$f"; exit 1; }; done

# ---- opus_top (engine + DDR4 key streams + CSR + io window) as the host drives it, keys in DDR4
# channel models in the board layout (sw/pack_ddr.py), mixed reductions as built: make top PLOG=5 KSL=184
TOP_OBJ := obj_dir_top_P$(PLOG)_L$(KSL)_$(shell hostname)
TOP_SRCS := $(XLIB) $(PKG) $(TOP_RTL) axi_ddr_model.sv tb_top.sv
.PHONY: top
$(TOP_OBJ)/Vtb_top: $(TOP_SRCS)
	@$(DUMPP) --plog $(PLOG) --red mont --jobs 3 --out $(VECROOT)/P$(PLOG)_mont_br > /dev/null
	@$(DUMPP) --plog $(PLOG) --red table --jobs 3 --out $(VECROOT)/P$(PLOG)_table_br > /dev/null
	verilator $(VFLAGS) -Wno-COMBDLY -Wno-WIDTHCONCAT --Mdir $(TOP_OBJ) --top-module tb_top -GPLOG=$(PLOG) -GBSLOG=3 -GKSL=$(KSL) \
	  -GRED_F=0 -GRED_M=1 -GRED_I=1 -GROMDIR_F='"$(VECROOT)/P$(PLOG)_mont_br"' -GROMDIR_I='"$(VECROOT)/P$(PLOG)_table_br"' $(TOP_SRCS)

CHAN_OBJ := obj_dir_chan_$(shell hostname)
chan:
	verilator --binary --timing -Wno-fatal -Wno-COMBDLY -Wno-WIDTHCONCAT -Wno-BLKSEQ --build-jobs $(JOBS) --Mdir $(CHAN_OBJ) \
	  --top-module tb_chan $(XLIB) $(RTL)/ddr_rd_streamer.sv $(RTL)/ddr_chan_rd.sv axi_ddr_model.sv tb_chan.sv > /dev/null
	@mkdir -p $(EVID3)
	@for s in $(SEEDS); do $(CHAN_OBJ)/Vtb_chan +seed=$$s > $(EVID3)/chan_s$$s.log 2>&1; tail -3 $(EVID3)/chan_s$$s.log; done
	@for s in $(SEEDS); do grep -q "^PASS tb_chan" $(EVID3)/chan_s$$s.log || { echo "NO PASS seed $$s"; exit 1; }; done

top: $(TOP_OBJ)/Vtb_top
	@mkdir -p $(EVID3)
	@for s in $(SEEDS); do ( K=../data/v28/ks32_s$$s; VA=$(VECROOT)/realtab_P$(PLOG)_s$$s; VB=$(VECROOT)/realtab_P$(PLOG)_s$${s}_b; \
	  KD=$(VECROOT)/ks_L$(KSL)_s$${s}_16; DD=$(VECROOT)/ddr_P$(PLOG)_L$(KSL)_s$$s; L=$(EVID3)/top_P$(PLOG)_L$(KSL)_s$$s.log; \
	  echo "# host $$(hostname) date $$(date -Iseconds) git $$(git rev-parse --short HEAD)" > $$L; \
	  [ -f $$VA/out.hex ] || $(DUMPE) real --keys $$K --plog $(PLOG) --slots 8 --first 0 --red table --out $$VA >> $$L 2>&1; \
	  [ -f $$VB/out.hex ] || $(DUMPE) real --keys $$K --plog $(PLOG) --slots 8 --first 8 --red table --out $$VB >> $$L 2>&1; \
	  [ -f $$KD/ksk.hex ] || $(DUMPE) ks --keys $$K --lanes $(KSL) --count 16 --out $$KD >> $$L 2>&1; \
	  mkdir -p $$DD; \
	  python3 ../sw/pack_ddr.py bsk $$VA/op_p249857.hex --bits $$((4*18<<$(PLOG))) --hex $$DD/ch0.hex >> $$L && \
	  python3 ../sw/pack_ddr.py bsk $$VA/op_p188417.hex --bits $$((4*18<<$(PLOG))) --hex $$DD/ch1.hex >> $$L && \
	  python3 ../sw/pack_ddr.py bsk $$VA/op_p163841.hex --bits $$((4*18<<$(PLOG))) --hex $$DD/ch3.hex >> $$L && \
	  python3 ../sw/pack_ddr.py ksk $$KD/ksk.hex --bits $$((32*$(KSL))) --hex $$DD/ch2.hex >> $$L && \
	  echo "$$ $(TOP_OBJ)/Vtb_top +vecA=$$VA +vecB=$$VB +ks=$$KD +ddr=$$DD +outA=$$VA/top_out.hex +outB=$$VB/top_out.hex" >> $$L && \
	  $(TOP_OBJ)/Vtb_top +vecA=$$VA +vecB=$$VB +ks=$$KD +ddr=$$DD +outA=$$VA/top_out.hex +outB=$$VB/top_out.hex >> $$L 2>&1 && \
	  python3 -c "import struct,sys; w=[int(l,16) for l in open(sys.argv[1])]+[int(l,16) for l in open(sys.argv[2])]; open(sys.argv[3],'wb').write(struct.pack('<%dQ'%len(w),*w))" $$VA/top_out.hex $$VB/top_out.hex $$VA/top_out16.u64 && \
	  echo "$$ tfhe_oracle decrypt --keys $$K --input $$VA/top_out16.u64 --kind pbs" >> $$L && \
	  $(ORACLE) decrypt --keys $$K --input $$VA/top_out16.u64 --kind pbs --json $$VA/top_dec16.json >> $$L 2>&1 && echo "PASS top: 16 outputs read back through the io window, decrypted by tfhe-rs" >> $$L ) & done; wait; \
	  for s in $(SEEDS); do grep -h "PASS\|FAILED\|ERROR\|opus_top\|KSK load\|\"failures\"\|log2_std" $(EVID3)/top_P$(PLOG)_L$(KSL)_s$$s.log; done; \
	  for s in $(SEEDS); do f=$(EVID3)/top_P$(PLOG)_L$(KSL)_s$$s.log; grep -q "^PASS top" $$f || { echo "NO PASS in $$f"; exit 1; }; done
