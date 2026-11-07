//! Twiddle ROMs and test vectors for the streaming NTT pipeline (rtl/ntt_pipe.sv) and the
//! streaming external product (rtl/extprod_pipe.sv). Layout: ref/tfhe_model/src/ntt_pipe.rs.
//!
//! dump_pipe --plog p --red mont|table [--seed S] [--jobs J] --out DIR
//!
//! A frame is N/P lines, line tau = the P paths' coefficients (path 0 in the low 18 bits).
//! Per prime pr (ntt_q::PRIMES):
//!   pf_p<pr>_s<i>.hex / pi_p<pr>_s<i>.hex: stage i twiddles, N/P lines, line tau = the P/2
//!       units' stored constants (unit 0 low), centre(w * C mod p), C = 2^18 (mont) or 1.
//!   pv_p<pr>_fwd_in.hex (block layout) -> pv_p<pr>_fwd_out.hex (forward output layout);
//!   pv_p<pr>_inv_in.hex (forward output layout) -> pv_p<pr>_inv_out.hex (block layout, x N);
//!       J frames each.
//!   px_p<pr>_d.hex: digit residues, per job D0 frame then D1 frame (block layout);
//!   px_p<pr>_op.hex: operands N^{-1} NTT(B_rc), stored form, forward output layout; per group of
//!       3 jobs N/P lines, line tau = {B11, B10, B01, B00} x P lanes (B00 lowest);
//!   px_p<pr>_out.hex: products O0 frame then O1 frame per job (block layout).
//! px_dsigned.hex: the shared signed digits (24-bit two's complement), D0 then D1 frame per job.
use std::fmt::Write as _;
use std::path::PathBuf;
use tfhe_model::ntt_pipe::Pipe;
use tfhe_model::ntt_q::{NttQ, PRIMES};

const N: usize = 2048;
const GROUP: usize = 3;

fn stored(w: u64, p: u64, mont: bool) -> u64 {
    let v = if mont { (w as u128 * (1u128 << 18) % p as u128) as u64 } else { w };
    let s = if v > p / 2 { v as i64 - p as i64 } else { v as i64 };
    (s as u64) & 0x3ffff
}

/// Big-endian hex of lanes (lane 0 lowest), `bits` per lane.
fn line(vals: &[u64], bits: usize) -> String {
    let total = bits * vals.len();
    let mut word = vec![0u8; total];
    for (l, &v) in vals.iter().enumerate() {
        for b in 0..bits {
            word[bits * l + b] = ((v >> b) & 1) as u8;
        }
    }
    let mut s = String::new();
    for d in (0..total.div_ceil(4)).rev() {
        let nib = (0..4).fold(0u8, |acc, b| acc | (word.get(4 * d + b).copied().unwrap_or(0) << b));
        write!(s, "{nib:x}").unwrap();
    }
    s
}

struct Lcg(u64);
impl Lcg {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        self.0 >> 20
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let get = |k: &str| args.iter().position(|a| a == k).map(|i| args[i + 1].clone());
    let plog: u32 = get("--plog").expect("--plog p").parse().unwrap();
    let red = get("--red").unwrap_or_else(|| "mont".into());
    let mont = red == "mont";
    let seed: u64 = get("--seed").unwrap_or_else(|| "1".into()).parse().unwrap();
    let jobs: usize = get("--jobs").unwrap_or_else(|| "6".into()).parse().unwrap();
    let out = PathBuf::from(get("--out").expect("--out DIR"));
    std::fs::create_dir_all(&out).unwrap();
    let pp = 1usize << plog;
    let frame = N >> plog;
    let fwd = Pipe::forward(11, plog);
    let inv = Pipe::inverse_of(&fwd);
    let fpos = fwd.output_positions(); // index tau*P + path -> position
    let bpos = inv.output_positions(); // block layout
    let to_frame = |v: &[u64], pos: &[usize]| -> Vec<String> {
        (0..frame).map(|tau| line(&(0..pp).map(|path| v[pos[tau * pp + path]]).collect::<Vec<_>>(), 18)).collect()
    };
    let qq: u128 = PRIMES.iter().map(|&p| p as u128).product();
    let mut gx = Lcg(seed.wrapping_mul(0x9e37_79b9) ^ 0x51ed);
    let digits: Vec<[Vec<i64>; 2]> = (0..jobs)
        .map(|_| [0, 1].map(|_| (0..N).map(|_| (gx.next() % (1 << 23)) as i64 - (1 << 22)).collect()))
        .collect();
    let ops: Vec<[[Vec<u64>; 2]; 2]> = (0..jobs.div_ceil(GROUP))
        .map(|_| [0, 1].map(|_| [0, 1].map(|_| (0..N).map(|_| ((gx.next() as u128 * gx.next() as u128) % qq) as u64).collect())))
        .collect();
    let mut ds = Vec::new();
    for d in &digits {
        for r in 0..2 {
            for tau in 0..frame {
                ds.push(line(&(0..pp).map(|path| (d[r][bpos[tau * pp + path]] as u64) & 0xff_ffff).collect::<Vec<_>>(), 24));
            }
        }
    }
    std::fs::write(out.join("px_dsigned.hex"), ds.join("\n") + "\n").unwrap();

    for &p in &PRIMES {
        let q = NttQ::new(p, N);
        for (pipe, tag) in [(&fwd, "pf"), (&inv, "pi")] {
            for i in 0..11 {
                let lines: Vec<String> = (0..frame)
                    .map(|tau| line(&(0..pp / 2).map(|u| stored(pipe.twiddle(&q, i, u, tau), p, mont)).collect::<Vec<_>>(), 18))
                    .collect();
                std::fs::write(out.join(format!("{tag}_p{p}_s{i}.hex")), lines.join("\n") + "\n").unwrap();
            }
        }
        let mut g = Lcg(seed.wrapping_mul(1_000_003) ^ p);
        let (mut fi, mut fo, mut ii, mut io) = (vec![], vec![], vec![], vec![]);
        for _ in 0..jobs {
            let a: Vec<u64> = (0..N).map(|_| g.next() % p).collect();
            fi.extend(to_frame(&a, &bpos));
            fo.extend(to_frame(&q.forward(&a), &fpos));
            let b: Vec<u64> = (0..N).map(|_| g.next() % p).collect();
            ii.extend(to_frame(&b, &fpos));
            io.extend(to_frame(&q.inverse_unscaled(&b), &bpos));
        }
        for (name, v) in [("fwd_in", fi), ("fwd_out", fo), ("inv_in", ii), ("inv_out", io)] {
            std::fs::write(out.join(format!("pv_p{p}_{name}.hex")), v.join("\n") + "\n").unwrap();
        }
        let m = |x: i64| x.rem_euclid(p as i64) as u64;
        let (mut xd, mut xop, mut xo) = (vec![], vec![], vec![]);
        for job in 0..jobs {
            let d = [0, 1].map(|r| digits[job][r].iter().map(|&x| m(x)).collect::<Vec<u64>>());
            let b = ops[job / GROUP].clone().map(|row| row.map(|poly| poly.iter().map(|&x| x % p).collect::<Vec<u64>>()));
            let (bp, _, prod) = q.ext_product(&d, &b);
            xd.extend(to_frame(&d[0], &bpos));
            xd.extend(to_frame(&d[1], &bpos));
            if job % GROUP == 0 {
                for tau in 0..frame {
                    let mut lanes = Vec::with_capacity(4 * pp);
                    for (r, c) in [(0, 0), (0, 1), (1, 0), (1, 1)] {
                        lanes.extend((0..pp).map(|path| stored(bp[r][c][fpos[tau * pp + path]], p, mont)));
                    }
                    xop.push(line(&lanes, 18));
                }
            }
            xo.extend(to_frame(&prod[0], &bpos));
            xo.extend(to_frame(&prod[1], &bpos));
        }
        for (name, v) in [("d", xd), ("op", xop), ("out", xo)] {
            std::fs::write(out.join(format!("px_p{p}_{name}.hex")), v.join("\n") + "\n").unwrap();
        }
    }
    println!("dump_pipe: P={pp} red={red} seed={seed} jobs={jobs} -> {}", out.display());
}
