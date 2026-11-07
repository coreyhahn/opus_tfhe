//! Twiddle ROMs and test vectors for the RTL transform core (rtl/ntt_cg.sv, rtl/extprod1.sv).
//!
//! dump_ntt --t T --red mont|table [--seed S] [--jobs J] --out DIR
//!
//! Per prime p (ntt_q::PRIMES):
//!   twf_p<p>.hex / twi_p<p>.hex (the directory names T and the reduction): 11*H lines (H = N/2T); line s*H + a holds the stored
//!       constants of lanes T-1..0 (lane 0 in the low 18 bits), 18-bit two's complement each:
//!       centre(w * C mod p), C = 2^18 (mont) or 1 (table). Forward lane l at (s, a) uses
//!       psi_rev[2^s + ((aT + l) mod 2^s)]; inverse uses psi_inv_rev[h + ((aT+l) mod h)], h = 2^(10-s).
//!   vec_p<p>_{fwd,inv}_{in,out}.hex: J jobs x 2 slots x N coefficients, one per line (5 hex digits).
//!   vec_xp_dsigned.hex: the shared signed digits (24-bit two's complement, 2N lines per job).
//!   vec_p<p>_xp_{d,op,out}.hex: external product: per job digit residues D0,D1 (2N lines), engine-form
//!       operands N^{-1} NTT(B_rc) in position order, stored form, order rc = 00,01,10,11 (4N lines),
//!       one operand set per group of XP_GROUP = 3 consecutive jobs,
//!       products O0,O1 (2N lines).
//! All values come from ref/tfhe_model/src/ntt_q.rs.
use std::fmt::Write as _;
use std::path::PathBuf;
use tfhe_model::ntt_q::{NttQ, PRIMES};

const N: usize = 2048;
const XP_GROUP: usize = 3;

fn centre_c(w: u64, p: u64, mont: bool) -> u64 {
    let v = if mont { (w as u128 * (1u128 << 18) % p as u128) as u64 } else { w };
    let s = if v > p / 2 { v as i64 - p as i64 } else { v as i64 };
    (s as u64) & 0x3ffff
}

fn rom_line(vals: &[u64]) -> String {
    // vals[l] for lane l (18 bits); lane 0 lowest. Big-endian hex of the 18T-bit word.
    let bits = 18 * vals.len();
    let mut word = vec![0u8; bits];
    for (l, &v) in vals.iter().enumerate() {
        for b in 0..18 {
            word[18 * l + b] = ((v >> b) & 1) as u8;
        }
    }
    let mut s = String::new();
    for d in (0..bits / 4).rev() {
        let nib = (0..4).fold(0u8, |acc, b| acc | (word[4 * d + b] << b));
        write!(s, "{nib:x}").unwrap();
    }
    s
}

fn write_lines(path: PathBuf, vals: impl Iterator<Item = u64>) {
    let mut s = String::new();
    for v in vals {
        writeln!(s, "{v:05x}").unwrap();
    }
    std::fs::write(&path, s).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
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
    let t: usize = get("--t").expect("--t T").parse().unwrap();
    let red = get("--red").unwrap_or_else(|| "mont".into());
    let mont = red == "mont";
    assert!(mont || red == "table");
    let seed: u64 = get("--seed").unwrap_or_else(|| "1".into()).parse().unwrap();
    let jobs: usize = get("--jobs").unwrap_or_else(|| "4".into()).parse().unwrap();
    let out = PathBuf::from(get("--out").expect("--out DIR"));
    std::fs::create_dir_all(&out).unwrap();
    let h = N / (2 * t);

    // external-product data shared by the three residues: signed 23-bit digits (one pair per job)
    // and operand integers mod Q (one set of 4 polynomials per group of XP_GROUP jobs)
    let qq: u128 = PRIMES.iter().map(|&p| p as u128).product();
    let mut gx = Lcg(seed.wrapping_mul(0x9e37_79b9) ^ 0x5eed);
    let xp_digits: Vec<[Vec<i64>; 2]> = (0..jobs)
        .map(|_| [0, 1].map(|_| (0..N).map(|_| (gx.next() % (1 << 23)) as i64 - (1 << 22)).collect()))
        .collect();
    let xp_ops: Vec<[[Vec<u64>; 2]; 2]> = (0..jobs.div_ceil(XP_GROUP))
        .map(|_| [0, 1].map(|_| [0, 1].map(|_| (0..N).map(|_| ((gx.next() as u128 * gx.next() as u128) % qq) as u64).collect())))
        .collect();
    write_lines(out.join("vec_xp_dsigned.hex"), xp_digits.iter().flat_map(|d| d[0].iter().chain(d[1].iter())).map(|&x| (x as u64) & 0xff_ffff));

    for &p in &PRIMES {
        let q = NttQ::new(p, N);
        // ROMs (independent of the seed)
        for (name, inv) in [("twf", false), ("twi", true)] {
            let mut s = String::new();
            for st in 0..11u32 {
                for a in 0..h {
                    let lanes: Vec<u64> = (0..t)
                        .map(|l| {
                            let w = if inv { q.inv_twiddle(st, a * t + l) } else { q.fwd_twiddle(st, a * t + l) };
                            centre_c(w, p, mont)
                        })
                        .collect();
                    writeln!(s, "{}", rom_line(&lanes)).unwrap();
                }
            }
            std::fs::write(out.join(format!("{name}_p{p}.hex")), s).unwrap();
        }
        // vectors
        let mut g = Lcg(seed.wrapping_mul(1_000_003) ^ p);
        let poly = |g: &mut Lcg| -> Vec<u64> { (0..N).map(|_| g.next() % p).collect() };
        let (mut fi, mut fo, mut ii, mut io) = (vec![], vec![], vec![], vec![]);
        let (mut xd, mut xop, mut xo) = (vec![], vec![], vec![]);
        for _ in 0..jobs {
            for _ in 0..2 {
                let a = poly(&mut g);
                fo.extend(q.forward(&a));
                fi.extend(a);
                let b = poly(&mut g);
                io.extend(q.inverse_unscaled(&b));
                ii.extend(b);
            }
        }
        write_lines(out.join(format!("vec_p{p}_fwd_in.hex")), fi.into_iter());
        write_lines(out.join(format!("vec_p{p}_fwd_out.hex")), fo.into_iter());
        write_lines(out.join(format!("vec_p{p}_inv_in.hex")), ii.into_iter());
        write_lines(out.join(format!("vec_p{p}_inv_out.hex")), io.into_iter());
        // external product: the shared signed digits / operand integers, reduced mod p
        let m = |x: i64| x.rem_euclid(p as i64) as u64;
        for job in 0..jobs {
            let d = [0, 1].map(|r| xp_digits[job][r].iter().map(|&x| m(x)).collect::<Vec<u64>>());
            let b = xp_ops[job / XP_GROUP].clone().map(|row| row.map(|poly| poly.iter().map(|&x| x % p).collect::<Vec<u64>>()));
            let (bp, _mac, prod) = q.ext_product(&d, &b);
            xd.extend(d[0].iter().chain(d[1].iter()).copied());
            if job % XP_GROUP == 0 {
                for r in 0..2 {
                    for c in 0..2 {
                        xop.extend(bp[r][c].iter().map(|&w| centre_c(w, p, mont)));
                    }
                }
            }
            xo.extend(prod[0].iter().chain(prod[1].iter()).copied());
        }
        write_lines(out.join(format!("vec_p{p}_xp_d.hex")), xd.into_iter());
        write_lines(out.join(format!("vec_p{p}_xp_op.hex")), xop.into_iter());
        write_lines(out.join(format!("vec_p{p}_xp_out.hex")), xo.into_iter());
    }
    println!("dump_ntt: T={t} red={red} seed={seed} jobs={jobs} -> {}", out.display());
}
