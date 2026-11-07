#!/usr/bin/env python3
"""DDR4 images of the keys in the board layout (docs/ARCHITECTURE.md §5).

  bsk: one residue's engine-form BSK (op_p<prime>.hex from dump_engine: NC*FR lines, one op
       word of 4*P*18 bits each) -> each word padded to whole 512-bit beats (5 at P = 32),
       least-significant beat first. Residue 0/1/2 go to DDR4 channel 0/1/3.
  ksk: the ks32-layout KSK (ksk.hex: one row of L*32 bits per line) -> rows padded to whole
       beats (12 at L = 184). It goes to channel 2.

Output: --hex (one 512-bit beat per line, for the Verilator DDR model's $readmemh) and/or
--bin (little-endian bytes, the image the host DMAs to the channel).
  pack_ddr.py bsk <op_pX.hex> --bits 2304 [--hex out.hex] [--bin out.bin]
  pack_ddr.py ksk <ksk.hex>   --bits 5888 [--hex out.hex] [--bin out.bin]
"""
import argparse
import sys

BEAT = 512


def pack(lines, bits):
    beats = (bits + BEAT - 1) // BEAT
    mask = (1 << BEAT) - 1
    for n, line in enumerate(lines):
        line = line.strip()
        if not line or line.startswith("//"):
            continue
        v = int(line, 16)
        if v >> bits:
            sys.exit(f"line {n + 1}: value wider than {bits} bits")
        for j in range(beats):
            yield (v >> (BEAT * j)) & mask


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("kind", choices=["bsk", "ksk"])
    ap.add_argument("src")
    ap.add_argument("--bits", type=int, required=True, help="payload bits per source line")
    ap.add_argument("--hex")
    ap.add_argument("--bin")
    a = ap.parse_args()
    if not a.hex and not a.bin:
        sys.exit("give --hex and/or --bin")
    fh = open(a.hex, "w") if a.hex else None
    fb = open(a.bin, "wb") if a.bin else None
    n = 0
    with open(a.src) as f:
        for b in pack(f, a.bits):
            if fh:
                fh.write(f"{b:0128x}\n")
            if fb:
                fb.write(b.to_bytes(BEAT // 8, "little"))
            n += 1
    for x in (fh, fb):
        if x:
            x.close()
    print(f"pack_ddr {a.kind}: {n} beats ({n * 64} bytes) from {a.src}")


if __name__ == "__main__":
    main()
