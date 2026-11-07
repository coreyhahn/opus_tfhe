#!/usr/bin/env python3
"""Stage 3 host tool: programmable bootstraps on the BCU-1525 through the full bitstream.

The data path is the one tb/tb_top.sv proves bit-exact in simulation (`make -C tb top PLOG=5
KSL=184`), built by the same generators:
  BSK  dump_engine real --plog 5 --slots 8 --first 0 --red table  -> op_p<prime>.hex
       sw/pack_ddr.py bsk ... --bits 2304 --bin                   -> ch0/ch1/ch3 images
  KSK  dump_engine ks --lanes 184 --count 16                      -> ksk.hex
       sw/pack_ddr.py ksk ... --bits 5888 --bin                   -> ch2 image
  LUT  lut_p<prime>.hex from the same dump_engine real run; word t of residue i (P*18 bits) goes
       little-endian into the first 96 bytes of io +0x100000 + (i*64 + t)*128 (tb_top's 3 beats)
  in   lwe_in.u64 of `tfhe_oracle gen` (2049 u64 per ciphertext, = dump_engine ks ct.hex),
       written as 2052 u64 (3 zero pad words, whole 32-byte beats: io_win ignores WSTRB) at
       io +((bank*8 + slot)*4096)*8
  out  2052 u64 read from io +0x200000 + ((bank*8 + slot)*4096)*8, first 2049 kept
CSR / io window / DDR4 layout: docs/ARCHITECTURE.md §5.  Param set
PARAM_MESSAGE_2_CARRY_2_KS32_PBS_TUNIFORM_2M128 (p-fail 2^-129.58), P = 32, 8 slots, KSL = 184.

Flow per key dir (one `tfhe_oracle gen --variant ks32 --seed S --count C` output):
  prep (cached in --prep, default <keys>/pbs_prep_P5_L184) -> board lock -> MAGIC/VERSION/CALIB
  -> DMA BSK to ch0/1/3 and KSK to ch2 (+ read-back check) -> BSK_BASE0..2, KSK_BASE -> CTRL.ksk_load,
  poll STATUS.ksk_busy -> LUT -> per run: all C ciphertexts in batches of 8 over both banks
  (bank b+1 is loaded and started while bank b runs), the last batch padded with copies of the
  last ciphertext -> outputs (tfhe_oracle `decrypt --kind pbs` format, LE u64, C x 2049) ->
  tfhe_oracle decrypt (checks against table[msg_in], the tb flow's check) + bit-exact compare with
  the engine model (<keys>/model_rns.pbs.u64 when present) -> evidence JSON + log.

Usage (board host, programmed with the full bitstream):
  PY=python3   # any python3 >= 3.8; stdlib only
  $PY sw/pbs_run.py --keys data/s1 --count 12500 --runs 2 --expect-version <hex8>
Offline (no device access, no lock): add --dry-run DIR (every DMA image + the CSR trace go to DIR;
the device is emulated, outputs come from --dry-model, default <keys>/model_rns.pbs.u64).
Prep only (no board needed): --prep-only.
"""
import argparse
import hashlib
import json
import mmap
import os
import shutil
import socket
import statistics
import subprocess
import sys
import time
from datetime import datetime, timezone

sys.path.insert(0, os.environ.get("FABLE5_SW", os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../fable5_llm/sw")))   # board_lock.py from the author's fable5_llm project
import board_lock as BL                                         # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# ---- engine / parameter set (docs/PARAMS.md, docs/ARCHITECTURE.md §5)
PARAM_SET = "PARAM_MESSAGE_2_CARRY_2_KS32_PBS_TUNIFORM_2M128"
P_FAIL = "2^-129.58"
PLOG, KSL, BS = 5, 184, 8
PP = 1 << PLOG
FR = 2048 // PP                       # 64 LUT / op words per residue
NC = 918                              # small LWE dimension (CMux count)
NW = 2049                             # u64 words per big LWE ciphertext
NWP = 2052                            # words per slot transfer (whole 32-byte beats)
CT_BYTES, SLOT_BYTES = NW * 8, NWP * 8
PRIMES = (249857, 188417, 163841)     # residue 0/1/2
RES_CH = (0, 1, 3)                    # DDR4 channel of residue i
KSK_CH = 2
BSK_BYTES = NC * FR * ((4 * PP * 18 + 511) // 512) * 64            # 18,800,640
KSK_BYTES = 2048 * 4 * ((NC + KSL) // KSL) * ((KSL * 32 + 511) // 512) * 64   # 31,457,280
LUT_BYTES = 3 * FR * 128

# ---- XDMA address map
CH_BASE = [c << 32 for c in range(4)]
CH_SIZE = 4 << 30
IO_BASE = 0x10_0000_0000
IO_IN, IO_LUT, IO_OUT = 0x000000, 0x100000, 0x200000
CHUNK = 64 << 20

# ---- CSR (AXI-Lite BAR, /dev/xdma0_user)
R_MAGIC, R_VERSION, R_SCRATCH, R_CALIB = 0x00, 0x04, 0x08, 0x0C
R_CTRL, R_STATUS, R_DONE = 0x40, 0x44, 0x48
R_BSK = (0x50, 0x54, 0x58)
R_KSK = 0x5C
R_BATCH, R_BUSY, R_WAIT = 0x60, 0x68, 0x70
CSR_NAME = {0x00: "MAGIC", 0x04: "VERSION", 0x08: "SCRATCH", 0x0C: "CALIB", 0x40: "CTRL",
            0x44: "STATUS", 0x48: "DONE_CNT", 0x50: "BSK_BASE0", 0x54: "BSK_BASE1",
            0x58: "BSK_BASE2", 0x5C: "KSK_BASE", 0x60: "BATCH_CYC_LO", 0x64: "BATCH_CYC_HI",
            0x68: "BUSY_CYC_LO", 0x6C: "BUSY_CYC_HI", 0x70: "BSK_WAIT_LO", 0x74: "BSK_WAIT_HI"}
MAGIC_EXPECT = 0x0F7FE001
CTRL_START, CTRL_KSK_LOAD = 0x1, 0x10
ST_KSK_BUSY, ST_BUSY = 1 << 3, 1 << 2

# bases tb_top uses (BB0/BB1/BB2/KB); any 4 KiB-aligned channel-local address works
DEF_BSK_BASES = (0x0010_0000, 0x0020_0000, 0x0030_0000)
DEF_KSK_BASE = 0x0040_0000


class Fail(Exception):
    """A refused precondition or a device timeout: recorded, and the tool exits non-zero."""


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 22), b""):
            h.update(b)
    return h.hexdigest()


class Log:
    def __init__(self):
        self.lines = []

    def __call__(self, msg=""):
        print(msg, flush=True)
        self.lines.append(msg)

    def save(self, path):
        with open(path, "w") as f:
            f.write("\n".join(self.lines) + "\n")


# ============================================================== prep (generators)
def tool_paths(args):
    tdir = "target-ctr" if os.environ.get("CARGO_TARGET_DIR") == "target-ctr" else "target"
    de = args.dump_engine or os.path.join(REPO, "ref/tfhe_model", tdir, "release/dump_engine")
    orc = args.oracle or os.path.join(REPO, "ref/tfhe_oracle", tdir, "release/tfhe_oracle")
    return de, orc


def run_cmd(cmd, log):
    log("$ " + " ".join(cmd))
    r = subprocess.run(cmd, capture_output=True, text=True)
    for ln in (r.stdout + r.stderr).strip().splitlines()[-4:]:
        log("  " + ln)
    if r.returncode != 0:
        raise Fail(f"command failed ({r.returncode}): {' '.join(cmd)}")


def prepare(keys, prep, dump_engine, log):
    """Byte images of the keys and the LUT, from the tb flow's generators; cached by key sha256."""
    meta = json.load(open(os.path.join(keys, "meta.json")))
    if not str(meta.get("param_set", "")).endswith(PARAM_SET) or meta.get("variant") != "ks32":
        raise Fail(f"{keys}: param_set {meta['param_set']} != {PARAM_SET}")
    fsha = {f["name"]: f["sha256"] for f in meta["files"]}
    pack = os.path.join(REPO, "sw/pack_ddr.py")
    want = {"keys_sha256": {n: fsha[n] for n in ("bsk.u64", "ksk.u32", "lut.u64")},
            "pack_ddr_sha256": sha256_file(pack), "plog": PLOG, "ksl": KSL, "red": "table"}
    stamp_f = os.path.join(prep, "stamp.json")
    if os.path.exists(stamp_f):
        st = json.load(open(stamp_f))
        if all(st.get(k) == v for k, v in want.items()):
            log(f"prep: {prep} is current (stamp matches keys + pack_ddr; images by "
                f"{st.get('dump_engine')} on {st.get('host')})")
            return st
        log(f"prep: {prep} is stale, regenerating")
    os.makedirs(prep, exist_ok=True)
    eng, ks = os.path.join(prep, "engine"), os.path.join(prep, "ks")
    for d in (eng, ks):
        shutil.rmtree(d, ignore_errors=True)
    ncks = min(16, int(meta["count"]))
    run_cmd([dump_engine, "real", "--keys", keys, "--plog", str(PLOG), "--slots", str(BS),
             "--first", "0", "--red", "table", "--out", eng], log)
    run_cmd([dump_engine, "ks", "--keys", keys, "--lanes", str(KSL), "--count", str(ncks),
             "--out", ks], log)
    images = {}
    for i, pr in enumerate(PRIMES):
        out = os.path.join(prep, f"ch{RES_CH[i]}.bin")
        run_cmd([sys.executable, pack, "bsk", os.path.join(eng, f"op_p{pr}.hex"),
                 "--bits", str(4 * 18 * PP), "--bin", out], log)
        images[f"ch{RES_CH[i]}"] = out
    out = os.path.join(prep, f"ch{KSK_CH}.bin")
    run_cmd([sys.executable, pack, "ksk", os.path.join(ks, "ksk.hex"), "--bits", str(32 * KSL),
             "--bin", out], log)
    images[f"ch{KSK_CH}"] = out
    # LUT window image: tb_top writes 768'(lut[i][t]) as beats {w[255:0], w[511:256], w[767:512]}
    # at +0x100000 + (i*FR + t)*128, i.e. the word little-endian in bytes 0..95 of the slot.
    lut = bytearray(LUT_BYTES)
    for i, pr in enumerate(PRIMES):
        lines = [ln.strip() for ln in open(os.path.join(eng, f"lut_p{pr}.hex")) if ln.strip()]
        if len(lines) != FR:
            raise Fail(f"lut_p{pr}.hex: {len(lines)} lines, want {FR}")
        for t, ln in enumerate(lines):
            v = int(ln, 16)
            if v >> (PP * 18):
                raise Fail(f"lut_p{pr}.hex line {t}: wider than {PP * 18} bits")
            o = (i * FR + t) * 128
            lut[o:o + 96] = v.to_bytes(96, "little")
    lut_f = os.path.join(prep, "lut_win.bin")
    with open(lut_f, "wb") as f:
        f.write(lut)
    sizes = {"ch0": BSK_BYTES, "ch1": BSK_BYTES, "ch3": BSK_BYTES, "ch2": KSK_BYTES}
    for k, fn in images.items():
        if os.path.getsize(fn) != sizes[k]:
            raise Fail(f"{fn}: {os.path.getsize(fn)} bytes, want {sizes[k]}")
    st = dict(want)
    st["dump_engine"], st["dump_engine_sha256"] = dump_engine, sha256_file(dump_engine)
    st["images"] = {k: {"file": os.path.basename(v), "bytes": os.path.getsize(v),
                        "sha256": sha256_file(v)} for k, v in images.items()}
    st["lut_win"] = {"file": "lut_win.bin", "bytes": LUT_BYTES, "sha256": sha256_file(lut_f)}
    st["generated"] = datetime.now(timezone.utc).isoformat()
    st["host"] = socket.gethostname()
    with open(stamp_f, "w") as f:
        json.dump(st, f, indent=1)
    log(f"prep: images written to {prep}")
    return st


# ============================================================== devices
class HwDev:
    """The board: CSR on <dev>_user, DMA on <dev>_h2c_0 / <dev>_c2h_0 (as sw/ddr_test.py)."""
    dry = False

    def __init__(self, dev):
        self.user = os.open(f"{dev}_user", os.O_RDWR)
        self.h2c_fd = os.open(f"{dev}_h2c_0", os.O_WRONLY)
        self.c2h_fd = os.open(f"{dev}_c2h_0", os.O_RDONLY)

    def rd(self, a):
        return int.from_bytes(os.pread(self.user, 4, a), "little")

    def wr(self, a, v):
        os.pwrite(self.user, int(v).to_bytes(4, "little"), a)

    def h2c(self, addr, data, name=None, off=0):
        # Stage through a page-aligned buffer: the XDMA driver splits a transfer at the source's
        # page boundaries, so an unaligned source gives card addresses off the 32-byte beat grid,
        # and io_win (no WSTRB, whole beats) would misplace those words.
        mv, done = memoryview(data), 0
        if not hasattr(self, "stage"):
            self.stage = mmap.mmap(-1, CHUNK)
        sv = memoryview(self.stage)
        while done < len(mv):
            k = min(CHUNK, len(mv) - done)
            sv[:k] = mv[done:done + k]
            n = os.pwrite(self.h2c_fd, sv[:k], addr + done)
            if n <= 0:
                raise Fail(f"H2C short write at {addr + done:#x}")
            done += n

    def c2h(self, addr, n):
        out = bytearray()
        while len(out) < n:
            b = os.pread(self.c2h_fd, min(CHUNK, n - len(out)), addr + len(out))
            if not b:
                raise Fail(f"C2H short read at {addr + len(out):#x}")
            out += b
        return bytes(out)

    def close(self):
        for fd in (self.user, self.h2c_fd, self.c2h_fd):
            os.close(fd)


class DryDev:
    """No device access. Records every DMA image (file `name` at `off`) and the CSR sequence in
    DIR/trace.txt, and emulates the board just enough to drive the tool's control flow: CSR
    reads answer as opus_csr would, the io window input/output regions are decoded as io_win.sv
    does, and a started batch "computes" each slot's output by looking its ciphertext up in
    `model` (the engine model's outputs for the key dir), so the output path is exercised."""
    dry = True

    def __init__(self, outdir, version, calib):
        self.dir = outdir
        os.makedirs(outdir, exist_ok=True)
        self.trace = open(os.path.join(outdir, "trace.txt"), "w")
        self.version, self.calib = version, calib
        self.scratch, self.ctrl_regs = 0, {a: 0 for a in (0x50, 0x54, 0x58, 0x5C)}
        self.bank_free, self.queue, self.done_cnt = [True, True], [], 0
        self.ksk_busy_reads, self.tick = 0, 0
        self.batch_cyc = self.busy_cyc = self.wait_cyc = 0
        self.last_bank = 0
        self.in_ram = [[bytearray(4096 * 8) for _ in range(BS)] for _ in range(2)]
        self.out_ram = [[bytearray(b"\xa5" * (4096 * 8)) for _ in range(BS)] for _ in range(2)]
        self.lookup, self.model = {}, None
        self.files = {}

    def set_model(self, lookup, model):
        self.lookup, self.model = lookup, model

    def t(self, s):
        self.trace.write(s + "\n")

    DRY_BATCH_TICKS = 24                      # emulated batch duration, in CSR accesses

    def _advance(self):
        self.tick += 1
        while self.queue and self.queue[0][1] <= self.tick:
            b, _ = self.queue.pop(0)
            self._compute(b)
            self.bank_free[b] = True
            self.done_cnt += 1
            self.last_bank = b
            self.batch_cyc = 478414               # placeholder figures (dry run, not silicon)
            self.busy_cyc += 478414

    def rd(self, a):
        self._advance()
        if a == R_MAGIC: v = MAGIC_EXPECT
        elif a == R_VERSION: v = self.version
        elif a == R_SCRATCH: v = self.scratch
        elif a == R_CALIB: v = self.calib
        elif a == R_STATUS:
            kb = self.ksk_busy_reads > 0
            if kb:
                self.ksk_busy_reads -= 1
            v = (int(self.bank_free[0]) | int(self.bank_free[1]) << 1 | int(bool(self.queue)) << 2
                 | int(kb) << 3 | self.last_bank << 4)
        elif a == R_DONE: v = self.done_cnt
        elif a in self.ctrl_regs: v = self.ctrl_regs[a]
        elif a in (0x60, 0x64): v = (self.batch_cyc >> (32 if a & 4 else 0)) & 0xFFFFFFFF
        elif a in (0x68, 0x6C): v = (self.busy_cyc >> (32 if a & 4 else 0)) & 0xFFFFFFFF
        elif a in (0x70, 0x74): v = (self.wait_cyc >> (32 if a & 4 else 0)) & 0xFFFFFFFF
        else: v = 0xDEADC0DE
        self.t(f"R  csr 0x{a:03x} {CSR_NAME.get(a, '?'):<12} -> 0x{v:08x}")
        return v

    def wr(self, a, v):
        self._advance()
        self.t(f"W  csr 0x{a:03x} {CSR_NAME.get(a, '?'):<12} <- 0x{v:08x}")
        if a == R_SCRATCH:
            self.scratch = v
        elif a in self.ctrl_regs:
            self.ctrl_regs[a] = v
        elif a == R_CTRL and self.calib == 0xF:
            if v & CTRL_START and self.bank_free[(v >> 1) & 1]:
                b = (v >> 1) & 1
                self.bank_free[b] = False
                prev = self.queue[-1][1] if self.queue else self.tick
                self.queue.append((b, max(prev, self.tick) + self.DRY_BATCH_TICKS))
            if v & CTRL_KSK_LOAD:
                self.ksk_busy_reads = 2

    def _compute(self, b):
        for c in range(BS):
            ct = bytes(self.in_ram[b][c][:CT_BYTES])
            i = self.lookup.get(hashlib.sha1(ct).digest())
            o = self.model[i * CT_BYTES:(i + 1) * CT_BYTES] if i is not None else bytes(CT_BYTES)
            self.out_ram[b][c][:CT_BYTES] = o

    def h2c(self, addr, data, name=None, off=0):
        h = hashlib.sha256(data).hexdigest()[:16]
        self.t(f"H2C 0x{addr:010x} len {len(data):>9} -> {name}@{off} sha256:{h}")
        if name:
            fn = os.path.join(self.dir, name)
            os.makedirs(os.path.dirname(fn), exist_ok=True)
            if fn not in self.files:
                self.files[fn] = open(fn, "r+b" if os.path.exists(fn) else "w+b")
                self.files[fn].truncate(0)
            f = self.files[fn]
            f.seek(off)
            f.write(data)
        if addr >= IO_BASE:                       # io_win write decode (input region only)
            wa = addr - IO_BASE
            if (wa >> 20) & 3 == 0:
                assert wa % 32 == 0 and len(data) % 32 == 0, "io window writes must be whole beats"
                for k in range(0, len(data), 8):
                    w = wa + k
                    bank, slot, idx = (w >> 18) & 1, (w >> 15) & 7, (w >> 3) & 0xFFF
                    self.in_ram[bank][slot][idx * 8:idx * 8 + 8] = data[k:k + 8]

    def c2h(self, addr, n):
        self.t(f"C2H 0x{addr:010x} len {n:>9}")
        wa = addr - IO_BASE
        if addr < IO_BASE or (wa >> 20) & 3 != 2:
            raise Fail("dry run: only io-window output reads are emulated")
        out = bytearray()
        for k in range(0, n, 8):
            w = wa + k
            bank, slot, idx = (w >> 18) & 1, (w >> 15) & 7, (w >> 3) & 0xFFF
            out += self.out_ram[bank][slot][idx * 8:idx * 8 + 8]
        return bytes(out)

    def close(self):
        for f in self.files.values():
            f.close()
        self.trace.close()


# ============================================================== device steps
def rd64(dev, a):
    """64-bit counter, hi-lo-hi so a carry between the two reads is not torn."""
    while True:
        hi = dev.rd(a + 4)
        lo = dev.rd(a)
        if dev.rd(a + 4) == hi:
            return (hi << 32) | lo


def check_device(dev, args, log):
    magic, version, calib = dev.rd(R_MAGIC), dev.rd(R_VERSION), dev.rd(R_CALIB)
    log(f"MAGIC={magic:08x} VERSION={version:08x} CALIB={calib:x}")
    if magic != MAGIC_EXPECT:
        raise Fail(f"MAGIC {magic:08x} != {MAGIC_EXPECT:08x}: wrong/old design loaded")
    if args.expect_version is not None and version != args.expect_version:
        raise Fail(f"VERSION {version:08x} != {args.expect_version:08x}: stale bitstream?")
    if calib & 0xF != 0xF:
        raise Fail(f"DDR4 CALIB={calib:04b}, need 1111: refusing to DMA")
    dev.wr(R_SCRATCH, 0xA5A5_5A5A)
    if dev.rd(R_SCRATCH) != 0xA5A5_5A5A:
        raise Fail("SCRATCH readback mismatch")
    st = dev.rd(R_STATUS)
    log(f"STATUS={st:08x} DONE_CNT={dev.rd(R_DONE)}")
    if st & (ST_BUSY | ST_KSK_BUSY) or st & 3 != 3:
        raise Fail(f"engine not idle (STATUS {st:08x}): a previous run did not finish")
    if (st >> 8) & 0xF:
        raise Fail(f"STATUS rresp error bits {(st >> 8) & 0xF:04b} already set")
    return version


def load_keys(dev, prep_dir, st, bsk_bases, ksk_base, args, log):
    t0 = time.monotonic()
    plan = [(RES_CH[i], bsk_bases[i]) for i in range(3)] + [(KSK_CH, ksk_base)]
    for ch, base in plan:
        img = open(os.path.join(prep_dir, f"ch{ch}.bin"), "rb").read()
        if hashlib.sha256(img).hexdigest() != st["images"][f"ch{ch}"]["sha256"]:
            raise Fail(f"ch{ch}.bin does not match its prep stamp")
        if base % 4096 or base + len(img) > CH_SIZE:
            raise Fail(f"ch{ch} base {base:#x}: not 4 KiB aligned or image past 4 GiB")
        tw = time.monotonic()
        dev.h2c(CH_BASE[ch] + base, img, name=f"ddr_ch{ch}_base_0x{base:08x}.bin")
        tw = time.monotonic() - tw
        msg = f"ch{ch}: {len(img)} bytes at channel offset {base:#x} ({len(img) / max(tw, 1e-9) / 1e6:.0f} MB/s)"
        if args.verify_keys and not dev.dry:
            back = dev.c2h(CH_BASE[ch] + base, len(img))
            if back != img:
                bad = next(i for i in range(len(img)) if back[i] != img[i])
                raise Fail(f"ch{ch} key image read-back differs first at byte {bad}")
            msg += ", read back bit-exact"
        log(msg)
    for i in range(3):
        dev.wr(R_BSK[i], bsk_bases[i])
    dev.wr(R_KSK, ksk_base)
    for a, v in list(zip(R_BSK, bsk_bases)) + [(R_KSK, ksk_base)]:
        if dev.rd(a) != v:
            raise Fail(f"{CSR_NAME[a]} readback mismatch")
    t_k = time.monotonic()
    dev.wr(R_CTRL, CTRL_KSK_LOAD)
    seen = False
    while True:
        s = dev.rd(R_STATUS)
        if s & ST_KSK_BUSY:
            seen = True
        elif seen:
            break
        if time.monotonic() - t_k > args.ksk_timeout:
            raise Fail(f"KSK load: ksk_busy {'never rose' if not seen else 'stuck'} "
                       f"after {args.ksk_timeout} s (STATUS {s:08x})")
    t_k = time.monotonic() - t_k
    if (s >> 8) & 0xF:
        raise Fail(f"KSK load: rresp error bits {(s >> 8) & 0xF:04b}")
    log(f"KSK load: {t_k * 1e3:.2f} ms host wall (STATUS {s:08x})")
    lut = open(os.path.join(prep_dir, "lut_win.bin"), "rb").read()
    for i in range(3):
        for t in range(FR):
            o = (i * FR + t) * 128
            dev.h2c(IO_BASE + IO_LUT + o, lut[o:o + 96], name="io_lut_window.bin", off=o)
    log(f"LUT: {3 * FR} words into io +0x100000; keys loaded in {time.monotonic() - t0:.2f} s")
    return {"ksk_load_ms": round(t_k * 1e3, 3)}


def run_batches(dev, lwe, count, run, args, log):
    """All `count` ciphertexts, 8 per batch, both banks. Returns (outputs bytearray, stats)."""
    nb = (count + BS - 1) // BS
    f = args.aclk_mhz * 1e6
    out = bytearray(count * CT_BYTES)
    pad = bytes(SLOT_BYTES - CT_BYTES)
    dmax = args.dry_batch_images

    def slot_ct(t, c):
        return min(t * BS + c, count - 1)          # the last batch is padded with the last ct

    def load(t):
        bank = t % 2
        img = name = None
        if dev.dry and (dmax < 0 or t < dmax):
            name = f"run{run}/batch{t:05d}_bank{bank}.bin"
        for c in range(BS):
            i = slot_ct(t, c)
            data = lwe[i * CT_BYTES:(i + 1) * CT_BYTES] + pad
            dev.h2c(IO_BASE + IO_IN + (bank * BS + c) * 4096 * 8, data, name=name, off=c * SLOT_BYTES)

    def start(t):
        bank, t0 = t % 2, time.monotonic()
        while not (dev.rd(R_STATUS) >> bank) & 1:
            if time.monotonic() - t0 > args.batch_timeout:
                raise Fail(f"run {run} batch {t}: bank {bank} not free after {args.batch_timeout} s")
        dev.wr(R_CTRL, CTRL_START | (bank << 1))

    done0, busy0, wait0 = dev.rd(R_DONE), rd64(dev, R_BUSY), rd64(dev, R_WAIT)
    per = []
    tw0 = time.monotonic()
    load(0); start(0)
    if nb > 1:
        load(1); start(1)
    for t in range(nb):
        bank, tp = t % 2, time.monotonic()
        while True:
            dc = dev.rd(R_DONE)
            if dc >= done0 + t + 1:
                break
            if time.monotonic() - tp > args.batch_timeout:
                raise Fail(f"run {run} batch {t}: DONE_CNT {dc} < {done0 + t + 1} after "
                           f"{args.batch_timeout} s (STATUS {dev.rd(R_STATUS):08x})")
        st = dev.rd(R_STATUS)
        bc = rd64(dev, R_BATCH)
        ambiguous = dev.rd(R_DONE) > done0 + t + 1   # BATCH_CYC may already be batch t+1's
        busy, wait = rd64(dev, R_BUSY), rd64(dev, R_WAIT)
        if (st >> 8) & 0xF:
            raise Fail(f"run {run} batch {t}: DDR4 rresp error bits {(st >> 8) & 0xF:04b}")
        # judge done_bank only by the DONE_CNT read after STATUS: batch t+1 may finish between
        # the poll above and the STATUS read (seed 4 batch 1488, 2026-11-03)
        if not ambiguous and ((st >> 4) & 1) != bank:
            raise Fail(f"run {run} batch {t}: STATUS last done_bank {(st >> 4) & 1} != {bank}")
        for c in range(BS):
            i = t * BS + c
            if i >= count:
                break
            b = dev.c2h(IO_BASE + IO_OUT + (bank * BS + c) * 4096 * 8, SLOT_BYTES)
            out[i * CT_BYTES:(i + 1) * CT_BYTES] = b[:CT_BYTES]
        per.append({"batch": t, "bank": bank, "batch_cyc": None if ambiguous else bc,
                    "busy_cyc_cum": busy - busy0, "bsk_wait_cum": wait - wait0,
                    "host_s": round(time.monotonic() - tw0, 6)})
        if t + 2 < nb:
            load(t + 2); start(t + 2)
        if (t + 1) % 500 == 0 or t + 1 == nb:
            log(f"  run {run}: {t + 1}/{nb} batches, {min((t + 1) * BS, count)} ct, "
                f"{time.monotonic() - tw0:.2f} s")
    wall = time.monotonic() - tw0
    busy_d = per[-1]["busy_cyc_cum"]
    lat = [p["batch_cyc"] for p in per if p["batch_cyc"] is not None]
    stats = {
        "batches": nb, "slots_padded": nb * BS - count, "host_wall_s": round(wall, 6),
        "pbs_per_s_host_wall": round(count / wall, 1),
        "busy_cyc": busy_d, "bsk_wait_cyc": per[-1]["bsk_wait_cum"],
        "pbs_per_s_busy_cyc": round(count / (busy_d / f), 1) if busy_d else None,
        "slot_pbs_per_s_busy_cyc": round(nb * BS / (busy_d / f), 1) if busy_d else None,
        "latency_first_batch_cyc": per[0]["batch_cyc"],
        "latency_first_batch_us": round(per[0]["batch_cyc"] / f * 1e6, 2) if per[0]["batch_cyc"] else None,
        "latency_batch_cyc_min_med_max": [min(lat), int(statistics.median(lat)), max(lat)] if lat else None,
        "latency_batch_us_min_med_max": [round(x / f * 1e6, 2) for x in
                                         (min(lat), statistics.median(lat), max(lat))] if lat else None,
        "batch_cyc_ambiguous": sum(p["batch_cyc"] is None for p in per),
        "per_batch": per,
    }
    return out, stats


# ============================================================== checks
def check_outputs(keys, out_f, out, count, oracle, model_f, log):
    res = {"output_file": out_f}
    if model_f and os.path.exists(model_f) and os.path.getsize(model_f) >= count * CT_BYTES:
        with open(model_f, "rb") as f:
            mm = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
            bad = [i for i in range(count)
                   if mm[i * CT_BYTES:(i + 1) * CT_BYTES] != out[i * CT_BYTES:(i + 1) * CT_BYTES]]
            mm.close()
        res["bitexact_vs_model"] = {"model": model_f, "mismatched_ct": len(bad), "first": bad[:16]}
        log(f"  bit-exact vs {os.path.basename(model_f)}: {count - len(bad)}/{count} ciphertexts equal")
    else:
        res["bitexact_vs_model"] = None
        log("  bit-exact check skipped (no model output covering the count)")
    dj = out_f[:-4] + ".dec.json"
    cmd = [oracle, "decrypt", "--keys", keys, "--input", out_f, "--kind", "pbs", "--json", dj]
    log("  $ " + " ".join(cmd))
    try:
        r = subprocess.run(cmd, capture_output=True, text=True)
        dec = json.load(open(dj)) if os.path.exists(dj) else None
    except OSError as e:
        r, dec = None, None
        log(f"  decrypt could not run: {e}")
    if dec is None or dec.get("count") != count:
        res["decrypt"] = {"error": "decrypt did not produce a result for every output",
                          "rc": None if r is None else r.returncode}
        res["failures"] = None
    else:
        res["decrypt"] = {k: dec[k] for k in ("count", "failures", "log2_std", "log2_max_abs",
                                              "margin_sigma", "mean", "std")}
        res["decrypt"]["failure_list"] = dec["failure_list"][:32]
        res["decrypt"]["json"] = dj
        res["failures"] = dec["failures"]
        log(f"  tfhe-rs decrypt: {dec['count']} ct, failures {dec['failures']}, "
            f"log2_std {dec['log2_std']:.2f}")
    return res


# ============================================================== main
def git_desc():
    def g(*a):
        return subprocess.run(["git", *a], capture_output=True, text=True, cwd=REPO).stdout.strip()
    return g("rev-parse", "HEAD") + ("-dirty" if g("status", "--porcelain", "--untracked-files=no") else "")


def hexint(s):
    return int(s, 16)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--keys", nargs="+", required=True,
                    help="tfhe_oracle gen --variant ks32 output dir(s); one per seed")
    ap.add_argument("--count", type=int, default=None, help="ciphertexts per run (default: all in keys)")
    ap.add_argument("--runs", type=int, default=1, help="runs per key dir, same keys, no reload")
    ap.add_argument("--prep", default=None, help="prep dir (default <keys>/pbs_prep_P5_L184); one key dir only")
    ap.add_argument("--out", default=None, help="output dir for the .u64 outputs (default <keys>/pbs_run/<ts>)")
    ap.add_argument("--evidence", default=None, help="evidence dir (default evidence/stage3/pbs_run, "
                    "or the --dry-run DIR)")
    ap.add_argument("--dev", default="/dev/xdma0")
    ap.add_argument("--expect-version", type=hexint, default=None,
                    help="CSR VERSION (git short8 hex) of the loaded bitstream; required on the board")
    ap.add_argument("--aclk-mhz", type=float, default=250.0)
    ap.add_argument("--bsk-bases", type=lambda s: [int(x, 0) for x in s.split(",")],
                    default=list(DEF_BSK_BASES), help="channel-local BSK bases for ch0,ch1,ch3")
    ap.add_argument("--ksk-base", type=lambda s: int(s, 0), default=DEF_KSK_BASE)
    ap.add_argument("--ksk-timeout", type=float, default=5.0, help="seconds")
    ap.add_argument("--batch-timeout", type=float, default=5.0, help="seconds per batch wait")
    ap.add_argument("--no-verify-keys", dest="verify_keys", action="store_false",
                    help="skip the read-back of the DDR4 key images")
    ap.add_argument("--model", default=None, help="engine-model outputs for the bit-exact check "
                    "(default <keys>/model_rns.pbs.u64 if present)")
    ap.add_argument("--dump-engine", default=None)
    ap.add_argument("--oracle", default=None)
    ap.add_argument("--prep-only", action="store_true", help="build/check the prep images and exit")
    ap.add_argument("--dry-run", metavar="DIR", default=None,
                    help="no device access: write every DMA image and the CSR trace into DIR")
    ap.add_argument("--dry-model", default=None, help="dry run: outputs the emulated engine returns "
                    "(LE u64, ct-indexed; default = --model)")
    ap.add_argument("--dry-calib", type=hexint, default=0xF, help="dry run: emulated CALIB (test the refusal)")
    ap.add_argument("--dry-batch-images", type=int, default=-1,
                    help="dry run: write input images of the first N batches per run (-1 = all)")
    BL.add_lock_args(ap)
    args = ap.parse_args()
    if args.prep and len(args.keys) > 1:
        ap.error("--prep with more than one --keys dir")
    if not args.dry_run and not args.prep_only and args.expect_version is None:
        ap.error("--expect-version is required on the board (guards against a stale bitstream)")
    if len(args.bsk_bases) != 3:
        ap.error("--bsk-bases needs three values (ch0,ch1,ch3)")

    log = Log()
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    dump_engine, oracle = tool_paths(args)
    keys_l = [os.path.abspath(k) for k in args.keys]
    metas = [json.load(open(os.path.join(k, "meta.json"))) for k in keys_l]
    preps = [os.path.abspath(args.prep) if args.prep else os.path.join(k, f"pbs_prep_P{PLOG}_L{KSL}")
             for k in keys_l]
    label = "dry-run (emulated device: NOT silicon; cycle counts are placeholders)" if args.dry_run else "silicon"
    ev = {"tool": "sw/pbs_run.py", "label": label, "utc": datetime.now(timezone.utc).isoformat(),
          "host": socket.gethostname(), "git": git_desc(), "argv": sys.argv,
          "param_set": PARAM_SET, "p_fail": P_FAIL, "P": PP, "batch": BS, "ksl": KSL,
          "aclk_mhz": args.aclk_mhz, "bsk_bases": [hex(b) for b in args.bsk_bases],
          "ksk_base": hex(args.ksk_base), "seeds": [], "pass": True}
    evid = args.evidence or (args.dry_run or os.path.join(REPO, "evidence/stage3/pbs_run"))
    os.makedirs(evid, exist_ok=True)
    tag = "dry_" if args.dry_run else ""
    stem = os.path.join(evid, f"pbs_run_{tag}{ts}_s" + "_".join(str(m["seed"]) for m in metas))
    log(f"# pbs_run {label} host {ev['host']} git {ev['git']} date {ev['utc']}")
    log("$ " + " ".join(sys.argv))

    dev, lock, rc = None, None, 0
    try:
        stamps = [prepare(k, p, dump_engine, log) for k, p in zip(keys_l, preps)]
        if args.prep_only:
            return 0
        # ---- device: lock first, before any device fd (dry run: neither)
        if args.dry_run:
            dev = DryDev(os.path.abspath(args.dry_run),
                         args.expect_version if args.expect_version is not None else 0, args.dry_calib)
        else:
            try:
                lock = BL.from_args(args, tool="pbs_run.py").acquire()
            except BL.BoardLockError as e:
                raise Fail(str(e))
            dev = HwDev(args.dev)
        ev["version"] = f"{check_device(dev, args, log):08x}"
        for k, prep, st, meta in zip(keys_l, preps, stamps, metas):
            seed = meta["seed"]
            count = args.count or int(meta["count"])
            if count > int(meta["count"]) or count < 1:
                raise Fail(f"{k}: --count {count} but the key dir has {meta['count']} ciphertexts")
            sev = {"seed": seed, "keys": k, "prep": prep, "count": count,
                   "images": st["images"], "lut_win": st["lut_win"], "runs": []}
            ev["seeds"].append(sev)
            log(f"== seed {seed}: {k}, {count} ciphertexts x {args.runs} run(s)")
            with open(os.path.join(k, "lwe_in.u64"), "rb") as f:
                lwe = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
            model_f = args.model or os.path.join(k, "model_rns.pbs.u64")
            if dev.dry:
                dm = args.dry_model or model_f
                model = open(dm, "rb").read() if os.path.exists(dm) else b""
                nm = len(model) // CT_BYTES
                dev.set_model({hashlib.sha1(lwe[i * CT_BYTES:(i + 1) * CT_BYTES]).digest(): i
                               for i in range(min(count, nm))}, model)
                log(f"dry run: emulated engine returns outputs from {dm} ({nm} ct)")
            sev.update(load_keys(dev, prep, st, args.bsk_bases, args.ksk_base, args, log))
            outdir = args.out or (os.path.join(os.path.abspath(args.dry_run), "out") if args.dry_run
                                  else os.path.join(k, "pbs_run", ts))
            os.makedirs(outdir, exist_ok=True)
            pending = []
            for run in range(args.runs):
                out, stats = run_batches(dev, lwe, count, run, args, log)
                out_f = os.path.join(outdir, f"pbs_out_s{seed}_run{run}.u64")
                with open(out_f, "wb") as f:
                    f.write(out)
                log(f"run {run}: {count} PBS in {stats['host_wall_s']:.3f} s = "
                    f"{stats['pbs_per_s_host_wall']} PBS/s host wall; BUSY_CYC {stats['busy_cyc']} -> "
                    f"{stats['pbs_per_s_busy_cyc']} PBS/s @ {args.aclk_mhz} MHz; first-batch latency "
                    f"{stats['latency_first_batch_us']} us; BSK_WAIT {stats['bsk_wait_cyc']}  [{label}]")
                rr = {"run": run, **stats}
                sev["runs"].append(rr)
                pending.append((rr, out_f, out))
            lwe.close()
            # checks are offline; for the board they run after this seed's device work
            for rr, out_f, out in pending:
                log(f"run {rr['run']} checks:")
                rr.update(check_outputs(k, out_f, out, count, oracle, model_f, log))
                bx = rr["bitexact_vs_model"]
                ok = rr["failures"] == 0 and (bx is None or bx["mismatched_ct"] == 0)
                rr["pass"] = ok
                ev["pass"] &= ok
    except Fail as e:
        log(f"FATAL: {e}")
        ev["pass"], ev["fatal"] = False, str(e)
        rc = 3
    finally:
        if dev is not None:
            dev.close()
        if lock is not None:
            lock.release()
    if args.prep_only and rc == 0:
        log("prep only: done")
        return 0
    for s in ev["seeds"]:
        for r in s["runs"]:
            log(f"seed {s['seed']} run {r['run']}: count {s['count']} failures {r.get('failures')} "
                f"bit-exact-mismatch {(r.get('bitexact_vs_model') or {}).get('mismatched_ct')} "
                f"PBS/s wall {r['pbs_per_s_host_wall']} busy {r['pbs_per_s_busy_cyc']} [{label}]")
    log("PASS" if ev["pass"] else "FAIL")
    with open(stem + ".json", "w") as f:
        json.dump(ev, f, indent=1)
    log(f"evidence: {stem}.json {stem}.log")
    log.save(stem + ".log")
    return rc or (0 if ev["pass"] else 1)


if __name__ == "__main__":
    sys.exit(main())
