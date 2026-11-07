# ARCHITECTURE — the PBS engine (Stage 2 design)

Status: Stage 2 design, 2026-10-20. This file fixes the dataflow, timing contracts and memories, so each block can
be built and verified on its own against `ref/tfhe_model/src/engine.rs`. Parameter set
`PARAM_MESSAGE_2_CARRY_2_KS32_PBS_TUNIFORM_2M128`: n = 918, N = 2048, k = 1, ℓ = 1, β = 23.

## 1. One engine, P = 32 paths, residue i in SLR i

```
            ┌──────────── SLR1 (+ shell, XDMA, DDR4 ch1/2) ─────────────────────────────────┐
 batch in → │ KS32 slice 1 ─┐                                  digit unit (6 DSP/coef) │
            │               ├─ sum ─ centred MS ─ ã RAM ─ CMux sequencer ─┐   ▲            │
            │ residue-1 slice: ACC1 ×2 copies, rotate, diff ──────────────┼───┘ y-diffs    │
            │                  xpipe1(p2) ← BSK1 double buffer ← DDR4      │   digits ▼     │
            │                  accumulate → ACC1, sample extract → ψ unit → batch out        │
            └────────────────────────────────────────────────────────────┼────────────────┘
   SLR0: KS32 slice 0, residue-0 slice (p1 = 249857), BSK0 buffer ← DDR4 ch0
   SLR2: KS32 slice 2, residue-2 slice (p3 = 163841), BSK2 buffer ← DDR4 ch3
```

Crossing the SLRs, per cycle (all registered at the SLR boundary):
- y-form diffs from SLR0/SLR2 to the digit unit: 2 polys × P × 18 = 1,152 bits each way.
- digits back to SLR0/SLR2: 2 × P × 24 = 1,536 bits.
- KS partial sums, once per ciphertext.

Budget: 17,280 SLLs per boundary.

## 2. Data layout

Every polynomial in flight is a **frame** of FR = N/P = 64 cycles × P lanes, in the
**block-per-path** layout: lane q at frame time τ holds position q·FR + τ. The forward NTT turns it
into the forward-output layout and the inverse restores it (ntt_pipe.rs). Residues are 18-bit
canonical; the accumulator is in y-form (engine.rs).

## 3. The blind-rotation loop

There are B ciphertext slots (B ≥ ⌈CMux latency / FR⌉ ≈ 10 at P = 32 for full throughput; fewer
slots run with bubbles). For CMux index i = 0..n−1 and slot c = 0..B−1, the sequencer issues one
frame:

1. **Rotated and unrotated read** of ACC_c (both polys), rotation by a = ã_{c,i}.
   - With a = A·FR + α (0 ≤ α < FR), output lane q at time τ reads source time τ_s = (τ − α)
     mod FR (common to all lanes) and virtual source lane v = (q − A − [τ < α]) mod 2P.
   - Value: lane (v mod P), negated mod p if v ≥ P.
   - The same address on every lane, then a P-way barrel rotation with per-lane negation.
2. **diff_y** = rot − unrot per residue (y-form, mod p_i). The three residues meet in the digit unit
   (§4.1), which gives 2 × P signed digits per cycle; these are broadcast back.
3. **digit → residue** (extprod3's 64-entry table), then **xpipe1** per residue.
   - The operands are BSK_i for this CMux index: N^{-1} (Q/p)^{-1} NTT(φ(b)) in forward-output
     layout, prepared by the host.
   - The frame carries the parity of i, which selects the operand buffer at the MAC.
4. **Accumulate**: ACC_c ← ACC_c + O (mod p_i, y-form), written to both ACC copies.
   - The unrotated ACC needed here is the one read in step 1, carried by a delay buffer of the
     xpipe latency (~512 deep × 2 polys × P × 18 bits per residue).
   - The two copies give 2 ports each: copy R serves the rotated read + write, copy U the
     unrotated read + write. That is 3 accesses per cycle without a third port.

ã_{c,i} = 0 needs no special case: the digits of a zero diff are 0 and O = 0, so the CMux is the
identity, exactly as the model's skip.

**Initialisation** of slot c (before i = 0), a frame type "init":
- mask ACC ← 0;
- body ACC ← rot(φ(LUT) y-form, −b̃_c), read from a LUT store with the same rotate unit.

**Completion** (after i = n−1), a frame type "extract":
- read ACC_c mask in reverse order with negation (out[0] = A[0], out[j] = −A[N−j]), plus body[0];
- the ψ unit maps y-form → u64: Σ y_i K'_i, K'_i = round(2^(64+28)/p_i), F = 28, serial;
- 2049 words per ciphertext to the output buffer.

## 4. Blocks and their bit-exact references

| Block | RTL | Reference | Status |
|---|---|---|---|
| modular multiplier, butterfly | modmul.sv, bfly.sv | ntt_q.rs | done (Stage 1) |
| NTT pipeline, external product | ntt_pipe*.sv, xpipe1/3.sv | ntt_pipe.rs, NttQ::ext_product | done (Stage 1b) |
| 4.1 digit unit | digit_unit.sv | Engine::digit_y (Rns::digit, F = 28) | **done**, 4 × 200k samples |
| 4.2 ACC store + rotate + diff | acc_slice.sv (+ lane_perm) | engine.rs blind_rotate (per-CMux trace) | **done**, 3 primes x 4 seeds |
| 4.3 CMux sequencer + BSK buffers | br_core.sv | engine.rs | **done**, synthetic + real keys |
| 4.4 sample extract + ψ | psi_unit.sv | Rns::psi | **done** |
| 4.5 KS32 + centred MS | ks32.sv | tfhe.rs keyswitch / modulus_switch_centered | **done**, bit-exact with tfhe-rs |
| 4.6 PBS engine top | pbs_engine.sv | tfhe_model run + tfhe-rs decrypt | **done**, 2 overlapped batches |

Pipeline facts the sequencer depends on (br_core `TLOOP`): acc_slice read latency 6 cycles
(address, RAM, RAM register, 3-stage lane_perm, subtract), accumulate latency 7 (address, RAM,
RAM register, 3-stage lane_perm, base, add, write). lane_perm splits the P-way rotation into
rr[1:0] (with the extract reversal), rr[PLOG-1:2], then the per-lane negation; the single-cycle
version was the critical path (-3.64 ns at 3.333 ns, br_P32_mont OOC).

pbs_engine batching: two input banks; KS of one bank overlaps the blind rotation of the other.
psi emits a slot as soon as its EXTRACT frame is complete (before br_core's done), so the
output bank is latched at the batch's first EXTRACT frame and `done` pulses with the batch's
last output word.

## 5. Host interface and the board top (Stage 3 design, 2026-10-20)

**Shell.** It is the fable5_llm pure-shell block design (build_007, commit 35d95a5). That design is
XDMA Gen3 x8 in Advanced mode, 256-bit at 250 MHz `axi_aclk`, AXI-Lite BAR 1 MB, plus 4 DDR4 MIG
(512-bit AXI at ui_clk ≈ 300 MHz) and the 5-clock SmartConnect that does the host-path CDC. The
CSR block is next to it. It measured 90k LUT, 152 BRAM36 and 0 URAM. The files are copied into
`synth/` with provenance headers. The engine enters as one module-reference cell
`opus_top_ipi.v`, a plain-Verilog wrapper, with X_INTERFACE attributes for every bus. Placement
is fixed by the IO: XDMA is in SLR1, ddr4_0 in SLR0, ddr4_1 and ddr4_2 in SLR1, ddr4_3 in SLR2.

**Engine clock.** The engine runs on `axi_aclk` at 250 MHz, per D6. A 300 MHz engine clock waits
for the D6 condition (OOC Fmax > 330 MHz). The only engine CDC is on the BSK and KSK stream
FIFOs (ui_clk → aclk, `xpm_fifo_async`) and on the stream requests (aclk → ui_clk).

**BSK in DDR4, residue i on its own channel (matches §1's residue-per-SLR).**

| | residue 0 (p1) | residue 1 (p2) | residue 2 (p3) | KSK load |
|---|---|---|---|---|
| DDR4 channel | ch0, SLR0 | ch1, SLR1 | ch3, SLR2 | ch2, SLR1 |

- One op word of one residue is 4·P·18 = 2,304 bits. It is padded to 5 beats of 512 bits
  (2,560).
- A CMux index needs FR = 64 words per residue: 320 beats, 20 KiB per channel, at
  `bsk_base_c + idx·20 KiB`. That is 18.4 MB per channel for n = 918.
- The `bsk_rd` reader runs one per channel on the ui_clk. It is fable5_llm's `ddr_rd_streamer`
  scheme: 512-bit INCR bursts of ≤ 64 beats that never cross 4 KiB, ≤ 4 outstanding, AR issue
  credited against FIFO space. It feeds an async FIFO of 512 × 512 bits (8 BRAM36).
- On `bsk_req` (idx, buf), the engine side posts idx to the three readers. The `bsk_asm` block
  pops the three FIFOs in lockstep, emits an op word every 5 cycles (`op_we`, all three
  residues at once, as `pbs_engine` takes them) and pulses `bsk_done` after 64 words.
- Rate: 320 cycles per CMux index, against ≈ 521 cycles of blind rotation per index (478,412 /
  918, batch 8). It needs 9.8 GB/s per channel at 250 MHz and 11.8 at 300. fable5_llm measured
  17.9 on silicon.
- The double-buffered request is issued one index ahead (br_core). The remaining margin covers
  the DDR read latency. A cycle counter `BSK_WAIT` counts the cycles br_core is stalled, and
  Stage 3 reports it.

**KSK.** The ks32 layout is 40,960 rows of L·32 = 5,888 bits. Each row is padded to 12 beats,
which makes 31.5 MB at `ksk_base` on ch2. On a `KSK_LOAD` pulse the ch2 reader streams it and
`ksk_asm` writes one row per 12 beats into ksk_ram. That takes ≈ 2 ms, once per key.

**Batches in and out: an AXI4 slave "io window"** on aclk at XDMA address 0x10_0000_0000. The
SmartConnect gives it one more master port; it is 256-bit with byte strobes.
- `+0x000000` input: (bank·8 + slot)·4096 + i, ×8 bytes, u64 words i = 0..2048 (masks then body).
  The writes go straight into `pbs_engine`'s input banks.
- `+0x100000` LUT: (res·2048 + coef) ×4 bytes, 18-bit values in u32. An assembler gathers P = 32
  coefficients into one `lut_we` word.
- `+0x200000` output: (bank·8 + slot)·4096 + i, ×8 bytes, read only. The `psi_unit` outputs
  (`o_*`) go into a 2 × 8 × 4096 × 64-bit output RAM of 15 URAM, in its own kept hierarchy
  (§4 lesson, ksk_ram).

A batch is: host DMA → input bank b, `CTRL.start(b)`; poll `STATUS` / `DONE_CNT`; C2H DMA of the
output bank. With two banks the host loads batch t+1 while batch t runs.

**CSR** (BAR offset 0, csr_block from fable5_llm plus the engine registers). Every read answers
in fixed time and no read waits on the engine.

| off | name | access | |
|---|---|---|---|
| 0x00–0x14 | MAGIC, VERSION, SCRATCH, CALIB, UPTIME | RO/RW | as fable5_llm; MAGIC 0x0F7FE001 |
| 0x40 | CTRL | W1P | b0 start, b1 start_bank, b4 ksk_load, b8 engine soft reset |
| 0x44 | STATUS | RO | b1:0 bank_free, b2 busy, b3 ksk_busy, b4 last done_bank, b8–11 rresp error per channel (sticky) |
| 0x48 | DONE_CNT | RO | batches completed since reset |
| 0x50/0x54/0x58 | BSK_BASE0/1/2 | RW | byte address in ch0/ch1/ch3, 4 KiB-aligned (the reader never realigns a burst) |
| 0x5C | KSK_BASE | RW | byte address in ch2, 4 KiB-aligned |
| 0x60/0x64 | BATCH_CYC | RO | start → done of the last batch, aclk cycles (latency) |
| 0x68/0x6C | BUSY_CYC | RO | cycles with the engine busy (throughput denominator) |
| 0x70/0x74 | BSK_WAIT | RO | cycles the blind rotation waited for a BSK index |
| 0x80– | SENSORS | RO | card power telemetry (D8), defined once the sensor path is proven |

`start` is ignored unless that bank is free and the CALIB bits for ch0–3 are all set. The DDR4
rule: no DMA and no engine read before CALIB.

**Verification order.**
1. `opus_top` (the engine plus bsk_rd/asm, ksk_asm, io window and CSR) in Verilator, with an
   AXI DDR model per channel: bit-exact and decrypted by tfhe-rs, 4 seeds.
2. Shell-only bitstream (MAGIC, VERSION, CALIB, DMA loopback).
3. Full bitstream.
