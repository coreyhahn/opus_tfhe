//! Exact-integer model of KS -> modulus switch -> blind rotation -> sample extraction.
//!
//! Written from the mathematical definitions (TFHE journal paper; tfhe-rs 1.8.2 semantics as
//! documented in docs/FORMATS.md). No tfhe-rs code. Two arithmetics for the blind rotation:
//!
//! * `Arith::Exact64`: the external product is computed exactly in Z_{2^64}[X]/(X^N+1) with
//!   tfhe-rs's balanced signed decomposition. The mathematical ideal tfhe-rs's f64 FFT
//!   approximates.
//! * `Arith::Rns`: the engine's arithmetic (docs/PARAMS.md). The accumulator lives in Z_Q,
//!   Q = p_1...p_m (small NTT primes), the BSK and LUT are mapped once into Z_Q by
//!   phi(t) = round(t*Q/2^64), digits come from an approximate-CRT decomposition with F
//!   fractional bits, and the sample-extracted output returns to Z_{2^64} through the same
//!   approximate-CRT map. Every step is an integer function: this is the RTL's bit-exact target.

use crate::swntt::{Engine, Prepared};

#[derive(Clone, Debug)]
pub struct Params {
    pub n: usize,
    pub k: usize,
    pub big_n: usize,
    pub pbs_base_log: u32,
    pub pbs_level: usize,
    pub ks_base_log: u32,
    pub ks_level: usize,
    pub ks_out_bits: u32, // 32 (KS32) or 64 (classic)
    pub delta_log2: u32,
}

impl Params {
    pub fn log2_2n(&self) -> u32 {
        (2 * self.big_n).trailing_zeros()
    }
}

// ---------------------------------------------------------------- decomposition (tfhe-rs rule)

/// Balanced signed decomposition of `x` (a 64-bit torus value) into `level` digits of base
/// 2^`base_log`, applied to the top base_log*level bits with round-half-up and tfhe-rs's
/// balancing and tie rules. Returns digits indexed by level j = 1..=level (index j-1), where level
/// j has weight 2^(64 - j*base_log).
pub fn decompose(x: u64, base_log: u32, level: usize) -> Vec<i64> {
    let rep = base_log * level as u32;
    let non_rep = 64 - rep;
    let mut res = x >> (non_rep - 1);
    let rounding_bit = res & 1;
    res = (res + 1) >> 1;
    let mask = if rep == 64 { u64::MAX } else { (1u64 << rep) - 1 };
    res &= mask;
    let half = 1u64 << (rep - 1);
    let need_balance = res > half || (res == half && rounding_bit == 1);
    let mut state = if need_balance { res.wrapping_sub(1u64 << rep) } else { res };
    let bmask = (1u64 << base_log) - 1;
    let mut digits = vec![0i64; level];
    for j in (1..=level).rev() {
        let r = state & bmask;
        state = ((state as i64) >> base_log) as u64;
        let carry = ((r.wrapping_sub(1) | state) & r) >> (base_log - 1);
        state = state.wrapping_add(carry);
        digits[j - 1] = r.wrapping_sub(carry << base_log) as i64;
    }
    digits
}

// ---------------------------------------------------------------- key switch

/// KSK as a flat array [k*N][ks_level][n+1] of words of ks_out_bits (u32 values widened to u64
/// for KS32). `level_index_of(j)` maps decomposition level j (1-based) to the stored index.
pub struct Ksk<'a> {
    pub words: &'a [u64],
    pub stored_level_for: Vec<usize>,
}

/// Keyswitch a big-key LWE (k*N mask + body, mod 2^64) to the small key, output mod 2^ks_out_bits
/// (returned in the low bits of u64). KS32: body rounded to its top 32 bits.
pub fn keyswitch(p: &Params, ksk: &Ksk, ct: &[u64]) -> Vec<u64> {
    let kn = p.k * p.big_n;
    let w = p.ks_out_bits;
    let wmask = if w == 64 { u64::MAX } else { (1u64 << w) - 1 };
    let mut out = vec![0u64; p.n + 1];
    let body = ct[kn];
    out[p.n] = if w == 64 {
        body
    } else {
        // closest representable with `w` bits at the top, then downscale
        let shift = 64 - w;
        (((body >> (shift - 1)).wrapping_add(1)) >> 1) & wmask
    };
    let stride = p.ks_level * (p.n + 1);
    for i in 0..kn {
        let digits = decompose(ct[i], p.ks_base_log, p.ks_level);
        for (j1, &d) in digits.iter().enumerate() {
            if d == 0 {
                continue;
            }
            let row = &ksk.words[i * stride + ksk.stored_level_for[j1] * (p.n + 1)..][..p.n + 1];
            let du = d as u64;
            for (o, &kw) in out.iter_mut().zip(row) {
                *o = o.wrapping_sub(kw.wrapping_mul(du)) & wmask;
            }
        }
    }
    out
}

// ---------------------------------------------------------------- centered-mean modulus switch

/// Centered-mean modulus switch of an LWE mod 2^w to mod 2N. Returns n masks then body, each in
/// [0, 2N).
pub fn modulus_switch_centered(p: &Params, ct: &[u64]) -> Vec<u64> {
    let w = p.ks_out_bits;
    let lg = p.log2_2n();
    let wmask = if w == 64 { u64::MAX } else { (1u64 << w) - 1 };
    let shift = w - lg;
    let ms = |a: u64| (a.wrapping_add(1u64 << (shift - 1)) & wmask) >> shift;
    // signed view of a w-bit value
    let signed = |a: u64| -> i128 {
        let a = (a & wmask) as i128;
        if w < 64 && a >= (1i128 << (w - 1)) { a - (1i128 << w) } else if w == 64 { a as u64 as i64 as i128 } else { a }
    };
    let mut sum_half: u64 = 0;
    let mut sum_halving_doubled: i128 = 0;
    for &a in &ct[..p.n] {
        let rounded = (ms(a) << shift) & wmask;
        let err = signed(rounded.wrapping_sub(a));
        let half = err / 2; // truncation toward zero, as the reference
        sum_half = sum_half.wrapping_add(half as i64 as u64) & wmask;
        sum_halving_doubled += 2 * half - err;
    }
    let sum_halving = (sum_halving_doubled / 2) as i64 as u64;
    let sum_half = sum_half.wrapping_sub(sum_halving) & wmask;
    let half_case = 1u64 << (shift - 1);
    let correction = sum_half.wrapping_sub(half_case) & wmask;
    let mut out: Vec<u64> = ct[..p.n].iter().map(|&a| ms(a)).collect();
    out.push(ms(ct[p.n].wrapping_add(correction) & wmask));
    out
}

// ---------------------------------------------------------------- LUT

/// shortint-style accumulator body: box size N/(msg*carry) filled with Delta*f(i); the first
/// half box negated; rotated left by half a box.
pub fn make_lut(p: &Params, f: &dyn Fn(u64) -> u64, msg_space: usize) -> Vec<u64> {
    let n = p.big_n;
    let box_size = n / msg_space;
    let mut acc = vec![0u64; n];
    for i in 0..msg_space {
        let v = f(i as u64).wrapping_mul(1u64 << p.delta_log2);
        acc[i * box_size..(i + 1) * box_size].fill(v);
    }
    let hb = box_size / 2;
    for a in acc[..hb].iter_mut() {
        *a = a.wrapping_neg();
    }
    acc.rotate_left(hb);
    acc
}

// ---------------------------------------------------------------- arithmetic

/// Fractional bits of the approximate CRT (digit and psi). 28 is the largest value for which the
/// digit unit maps onto a 6-DSP48E2 cascade (K_i = round(2^(23+F)/p_i) < 2^34, split 17 + 17);
/// the approximation error is then <= 3 * 2^18 * 2^-29 < 0.0015 of a digit unit.
pub const FRAC_BITS: u32 = 28;

#[derive(Clone, Debug)]
pub struct Rns {
    pub primes: Vec<u64>,
    pub q: u128,
    pub frac_bits: u32, // F: fixed-point fractional bits of the approximate CRT
    y_inv: Vec<u64>,    // (Q/p_i)^{-1} mod p_i
    k_digit: Vec<u128>, // round(B * 2^F / p_i)
    k_out: Vec<u128>,   // round(2^64 * 2^F / p_i)
}

impl Rns {
    pub fn new(primes: Vec<u64>, frac_bits: u32, pbs_base_log: u32) -> Self {
        let q: u128 = primes.iter().map(|&p| p as u128).product();
        assert!(q < (1u128 << 64), "model keeps Q < 2^64");
        let y_inv = primes
            .iter()
            .map(|&pi| {
                let qi = ((q / pi as u128) % pi as u128) as u64;
                modpow(qi, pi - 2, pi)
            })
            .collect();
        let rdiv = |num_log2: u32, p: u64| -> u128 {
            // round(2^num_log2 / p) for num_log2 <= 127
            let num = 1u128 << num_log2;
            (num + p as u128 / 2) / p as u128
        };
        let k_digit = primes.iter().map(|&pi| rdiv(pbs_base_log + frac_bits, pi)).collect();
        let k_out = primes.iter().map(|&pi| rdiv(64 + frac_bits, pi)).collect();
        Rns { primes, q, frac_bits, y_inv, k_digit, k_out }
    }

    /// phi: Z_{2^64} -> Z_Q, round(t * Q / 2^64) (host side: BSK, LUT).
    pub fn phi(&self, t: u64) -> u64 {
        // t*Q < 2^128 because Q < 2^64
        let prod = (t as u128) * self.q;
        let r = (prod >> 64) + ((prod >> 63) & 1);
        (r % self.q) as u64
    }

    /// The approximate-CRT sum S = sum_i y_i * K_i where y_i = x_i (Q/p_i)^{-1} mod p_i.
    fn crt_sum(&self, x: u64, ks: &[u128]) -> u128 {
        let mut s: u128 = 0;
        for (i, &pi) in self.primes.iter().enumerate() {
            let xi = x % pi;
            let yi = ((xi as u128 * self.y_inv[i] as u128) % pi as u128) as u128;
            s = s.wrapping_add(yi * ks[i]);
        }
        s
    }

    /// Digit for pbs_level = 1: round(x * B / Q) mod B, centred into [-B/2, B/2).
    pub fn digit(&self, x: u64, base_log: u32) -> i64 {
        let s = self.crt_sum(x, &self.k_digit);
        let f = self.frac_bits;
        let d = ((s + (1u128 << (f - 1))) >> f) as u64 & ((1u64 << base_log) - 1);
        if d >= 1u64 << (base_log - 1) { d as i64 - (1i64 << base_log) } else { d as i64 }
    }

    /// psi: Z_Q -> Z_{2^64}, round(x * 2^64 / Q) mod 2^64 via the same approximate CRT.
    pub fn psi(&self, x: u64) -> u64 {
        let s = self.crt_sum(x, &self.k_out);
        let f = self.frac_bits;
        ((s + (1u128 << (f - 1))) >> f) as u64
    }
}

fn modpow(mut b: u64, mut e: u64, m: u64) -> u64 {
    let mut r = 1u128;
    let mut bb = (b % m) as u128;
    while e > 0 {
        if e & 1 == 1 {
            r = r * bb % m as u128;
        }
        bb = bb * bb % m as u128;
        e >>= 1;
    }
    b = r as u64;
    b
}

#[derive(Clone, Debug)]
pub enum Arith {
    Exact64,
    Rns(Rns),
}

impl Arith {
    pub fn name(&self) -> String {
        match self {
            Arith::Exact64 => "exact64".into(),
            Arith::Rns(r) => format!(
                "rns[{}]F{} (log2 Q = {:.3})",
                r.primes.iter().map(|p| p.to_string()).collect::<Vec<_>>().join(","),
                r.frac_bits,
                (r.q as f64).log2()
            ),
        }
    }
    fn add(&self, a: u64, b: u64) -> u64 {
        match self {
            Arith::Exact64 => a.wrapping_add(b),
            Arith::Rns(r) => ((a as u128 + b as u128) % r.q) as u64,
        }
    }
    fn neg(&self, a: u64) -> u64 {
        match self {
            Arith::Exact64 => a.wrapping_neg(),
            Arith::Rns(r) => if a == 0 { 0 } else { (r.q - a as u128) as u64 },
        }
    }
    fn sub(&self, a: u64, b: u64) -> u64 {
        self.add(a, self.neg(b))
    }
    /// Map a torus value into the accumulator ring.
    pub fn from_torus(&self, t: u64) -> u64 {
        match self {
            Arith::Exact64 => t,
            Arith::Rns(r) => r.phi(t),
        }
    }
    pub fn to_torus(&self, x: u64) -> u64 {
        match self {
            Arith::Exact64 => x,
            Arith::Rns(r) => r.psi(x),
        }
    }
    /// Centred integer lift of a ring element (operand of the exact convolution).
    fn lift(&self, x: u64) -> i64 {
        match self {
            Arith::Exact64 => x as i64,
            Arith::Rns(r) => {
                let q = r.q as u64;
                if x > q / 2 { (x as i128 - q as i128) as i64 } else { x as i64 }
            }
        }
    }
    fn reduce(&self, v: i128) -> u64 {
        match self {
            Arith::Exact64 => v as u64,
            Arith::Rns(r) => v.rem_euclid(r.q as i128) as u64,
        }
    }
    fn digits(&self, p: &Params, x: u64) -> Vec<i64> {
        match self {
            Arith::Exact64 => decompose(x, p.pbs_base_log, p.pbs_level),
            Arith::Rns(r) => {
                assert_eq!(p.pbs_level, 1, "RNS decomposition modelled for pbs_level = 1");
                vec![r.digit(x, p.pbs_base_log)]
            }
        }
    }
}

// ---------------------------------------------------------------- bootstrap key

/// Standard-domain BSK [n][(k+1)*l rows][k+1 cols][N] mapped into the accumulator ring and
/// pre-transformed for the exact convolution engine.
pub struct PreparedBsk {
    pub ggsw: Vec<Vec<Vec<Prepared>>>, // [i][row][col]
}

pub fn prepare_bsk(p: &Params, arith: &Arith, eng: &Engine, bsk: &[u64]) -> PreparedBsk {
    use rayon::prelude::*;
    let rows = (p.k + 1) * p.pbs_level;
    let cols = p.k + 1;
    let nn = p.big_n;
    let ggsw = (0..p.n)
        .into_par_iter()
        .map(|i| {
            (0..rows)
                .map(|r| {
                    (0..cols)
                        .map(|c| {
                            let off = ((i * rows + r) * cols + c) * nn;
                            let poly: Vec<i64> = bsk[off..off + nn].iter().map(|&t| arith.lift(arith.from_torus(t))).collect();
                            eng.prepare(&poly)
                        })
                        .collect()
                })
                .collect()
        })
        .collect();
    PreparedBsk { ggsw }
}

// ---------------------------------------------------------------- blind rotation

/// poly * X^e in the negacyclic ring, e in [0, 2N).
fn rotate(arith: &Arith, poly: &[u64], e: usize) -> Vec<u64> {
    let n = poly.len();
    let mut out = vec![0u64; n];
    for (j, &v) in poly.iter().enumerate() {
        let t = (j + e) % (2 * n);
        if t < n { out[t] = v } else { out[t - n] = arith.neg(v) }
    }
    out
}

/// Row order of the GGSW: row r*l + (j-1) multiplies the level-j digit of GLWE component r
/// (components: k masks then the body).
pub fn blind_rotate_extract(p: &Params, arith: &Arith, eng: &Engine, bsk: &PreparedBsk, lut: &[u64], ms: &[u64]) -> Vec<u64> {
    let nn = p.big_n;
    let cols = p.k + 1;
    let two_n = 2 * nn;
    let body = ms[p.n] as usize;
    let lut_ring: Vec<u64> = lut.iter().map(|&t| arith.from_torus(t)).collect();
    // ACC = (0, ..., 0, X^{-b~} * LUT)
    let mut acc: Vec<Vec<u64>> = vec![vec![0u64; nn]; cols];
    acc[p.k] = rotate(arith, &lut_ring, (two_n - body) % two_n);
    for i in 0..p.n {
        let a = ms[i] as usize;
        if a == 0 {
            continue; // X^0 * ACC - ACC = 0: the CMux is the identity
        }
        let mut digit_polys: Vec<Vec<i64>> = vec![vec![0i64; nn]; cols * p.pbs_level];
        for c in 0..cols {
            let rot = rotate(arith, &acc[c], a);
            for j in 0..nn {
                let diff = arith.sub(rot[j], acc[c][j]);
                for (l, d) in arith.digits(p, diff).into_iter().enumerate() {
                    digit_polys[c * p.pbs_level + l][j] = d;
                }
            }
        }
        let ops: Vec<Vec<&Prepared>> = bsk.ggsw[i].iter().map(|row| row.iter().collect()).collect();
        let prod = eng.mac(&digit_polys, &ops, cols);
        for c in 0..cols {
            for j in 0..nn {
                acc[c][j] = arith.add(acc[c][j], arith.reduce(prod[c][j]));
            }
        }
    }
    // sample extraction of coefficient 0
    let mut out = vec![0u64; p.k * nn + 1];
    for c in 0..p.k {
        out[c * nn] = arith.to_torus(acc[c][0]);
        for j in 1..nn {
            out[c * nn + j] = arith.to_torus(arith.neg(acc[c][nn - j]));
        }
    }
    out[p.k * nn] = arith.to_torus(acc[p.k][0]);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decompose_reconstructs_closest_representable() {
        let mut x = 0x0123_4567_89ab_cdefu64;
        for _ in 0..10000 {
            x = x.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            for &(b, l) in &[(4u32, 4usize), (23, 1), (2, 8), (10, 2)] {
                let d = decompose(x, b, l);
                let mut rec = 0u64;
                for (j1, &dj) in d.iter().enumerate() {
                    assert!(dj >= -(1i64 << (b - 1)) && dj <= (1i64 << (b - 1)));
                    rec = rec.wrapping_add((dj as u64).wrapping_mul(1u64 << (64 - (j1 as u32 + 1) * b)));
                }
                let non_rep = 64 - b * l as u32;
                let err = x.wrapping_sub(rec) as i64;
                assert!(err.unsigned_abs() <= 1u64 << (non_rep - 1), "x={x:#x} b={b} l={l}");
            }
        }
    }

    #[test]
    fn rns_digit_matches_exact_rounding() {
        let r = Rns::new(vec![249857, 188417, 163841], 32, 23);
        let q = r.q;
        let mut x = 7u64;
        let mut mism = 0;
        for _ in 0..200000 {
            x = x.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            let v = (x as u128 % q) as u64;
            // exact round(v * B / Q) mod B, centred
            let num = (v as u128) << 23;
            let e = ((num + q / 2) / q) as u64 & ((1 << 23) - 1);
            let e = if e >= 1 << 22 { e as i64 - (1 << 23) } else { e as i64 };
            if r.digit(v, 23) != e {
                mism += 1;
            }
            let back = r.psi(v);
            let exact = (((v as u128) << 64) + q / 2) / q;
            assert!((back as i128 - exact as u64 as i128).abs() <= 1 || (back as i128 - exact as u64 as i128).unsigned_abs() >= u64::MAX as u128 - 1);
        }
        assert!(mism < 20, "approximate CRT disagreed with exact rounding {mism} times");
    }
}
