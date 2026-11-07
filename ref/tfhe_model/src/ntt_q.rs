//! The engine's per-residue negacyclic NTT, in the RTL's exact order (Stage 1 bit-exact target).
//!
//! Constant-geometry (Pease) form, N = 2^L points, prime p = 1 mod 2N, psi a primitive 2N-th root:
//!
//! * forward, stage s = 0..L-1, butterfly i = 0..N/2-1 (Cooley-Tukey, twist merged):
//!     u = x[i], v = x[i + N/2], w = psi_rev[2^s + (i mod 2^s)]
//!     y[2i] = u + w v,  y[2i+1] = u - w v
//!   Natural order in, output position p holds the same value as the in-place Longa-Naehrig NTT
//!   (bit-reversed evaluation order), because position = rotl^s(in-place index) at stage s.
//! * inverse, stage r = 0..L-1, butterfly i (Gentleman-Sande, transpose of the above):
//!     u = x[2i], v = x[2i+1], h = 2^(L-1-r), w = psi_inv_rev[h + (i mod h)]
//!     y[i] = u + v,  y[i + N/2] = (u - v) w
//!   Position-order in, natural order out, UNSCALED (result = N * a). The N^{-1} is folded into
//!   the BSK operand on the host.
//!
//! psi_rev[k] = psi^{bitrev_L(k)}, psi_inv_rev[k] = psi^{-bitrev_L(k)}. All values canonical in
//! [0, p) after every butterfly. psi is fixed per prime by `root_2n` (smallest g whose
//! g^((p-1)/2N) has order 2N) and recorded in every dump.

pub const PRIMES: [u64; 3] = [249857, 188417, 163841];

pub fn pow_mod(b: u64, mut e: u64, p: u64) -> u64 {
    let (mut r, mut b) = (1u64, b % p);
    while e > 0 {
        if e & 1 == 1 {
            r = r * b % p;
        }
        b = b * b % p;
        e >>= 1;
    }
    r
}

/// Primitive 2N-th root of unity: g^((p-1)/2N) for the smallest g in 2.. that has order 2N.
pub fn root_2n(p: u64, n: usize) -> u64 {
    assert_eq!((p - 1) % (2 * n as u64), 0);
    for g in 2..p {
        let w = pow_mod(g, (p - 1) / (2 * n as u64), p);
        if pow_mod(w, n as u64, p) == p - 1 {
            return w;
        }
    }
    unreachable!()
}

fn bitrev(x: usize, bits: u32) -> usize {
    x.reverse_bits() >> (usize::BITS - bits)
}

#[derive(Clone, Debug)]
pub struct NttQ {
    pub p: u64,
    pub n: usize,
    pub log_n: u32,
    pub psi: u64,
    pub psi_rev: Vec<u64>,
    pub psi_inv_rev: Vec<u64>,
}

impl NttQ {
    pub fn new(p: u64, n: usize) -> Self {
        assert!(p < 1 << 18 && n.is_power_of_two());
        let log_n = n.trailing_zeros();
        let psi = root_2n(p, n);
        let psi_inv = pow_mod(psi, p - 2, p);
        let psi_rev = (0..n).map(|k| pow_mod(psi, bitrev(k, log_n) as u64, p)).collect();
        let psi_inv_rev = (0..n).map(|k| pow_mod(psi_inv, bitrev(k, log_n) as u64, p)).collect();
        NttQ { p, n, log_n, psi, psi_rev, psi_inv_rev }
    }

    pub fn fwd_twiddle(&self, s: u32, i: usize) -> u64 {
        self.psi_rev[(1 << s) + (i & ((1 << s) - 1))]
    }

    pub fn inv_twiddle(&self, r: u32, i: usize) -> u64 {
        let h = 1usize << (self.log_n - 1 - r);
        self.psi_inv_rev[h + (i & (h - 1))]
    }

    /// One forward stage s.
    pub fn fwd_stage(&self, s: u32, x: &[u64]) -> Vec<u64> {
        let (p, h) = (self.p, self.n / 2);
        let mut y = vec![0u64; self.n];
        for i in 0..h {
            let (u, v) = (x[i], x[i + h]);
            let t = self.fwd_twiddle(s, i) * v % p;
            y[2 * i] = (u + t) % p;
            y[2 * i + 1] = (u + p - t) % p;
        }
        y
    }

    /// One inverse stage r.
    pub fn inv_stage(&self, r: u32, x: &[u64]) -> Vec<u64> {
        let (p, h) = (self.p, self.n / 2);
        let mut y = vec![0u64; self.n];
        for i in 0..h {
            let (u, v) = (x[2 * i], x[2 * i + 1]);
            y[i] = (u + v) % p;
            y[i + h] = (u + p - v) % p * self.inv_twiddle(r, i) % p;
        }
        y
    }

    /// Forward NTT, returning every stage output (last = result).
    pub fn forward_stages(&self, a: &[u64]) -> Vec<Vec<u64>> {
        let mut out = Vec::new();
        let mut x = a.to_vec();
        for s in 0..self.log_n {
            x = self.fwd_stage(s, &x);
            out.push(x.clone());
        }
        out
    }

    pub fn inverse_stages(&self, a: &[u64]) -> Vec<Vec<u64>> {
        let mut out = Vec::new();
        let mut x = a.to_vec();
        for r in 0..self.log_n {
            x = self.inv_stage(r, &x);
            out.push(x.clone());
        }
        out
    }

    pub fn forward(&self, a: &[u64]) -> Vec<u64> {
        self.forward_stages(a).pop().unwrap()
    }

    pub fn inverse_unscaled(&self, a: &[u64]) -> Vec<u64> {
        self.inverse_stages(a).pop().unwrap()
    }

    pub fn n_inv(&self) -> u64 {
        pow_mod(self.n as u64, self.p - 2, self.p)
    }

    /// External product of the engine for k = 1, one residue: digits D[r] (r = 0,1) in [0,p),
    /// operands B[r][c] in coefficient domain; returns (prepared operands in engine form =
    /// N^{-1} * NTT(B), the MAC outputs in NTT domain, the products O[c] = sum_r D[r] * B[r][c]).
    pub fn ext_product(&self, d: &[Vec<u64>; 2], b: &[[Vec<u64>; 2]; 2]) -> ([[Vec<u64>; 2]; 2], [Vec<u64>; 2], [Vec<u64>; 2]) {
        let p = self.p;
        let ninv = self.n_inv();
        let prep = |x: &Vec<u64>| -> Vec<u64> { self.forward(x).iter().map(|&v| v * ninv % p).collect() };
        let bp = [[prep(&b[0][0]), prep(&b[0][1])], [prep(&b[1][0]), prep(&b[1][1])]];
        let dh = [self.forward(&d[0]), self.forward(&d[1])];
        let mac: [Vec<u64>; 2] = [0, 1].map(|c| (0..self.n).map(|j| (dh[0][j] * bp[0][c][j] + dh[1][j] * bp[1][c][j]) % p).collect());
        let out = [self.inverse_unscaled(&mac[0]), self.inverse_unscaled(&mac[1])];
        (bp, mac, out)
    }
}

/// Schoolbook negacyclic product mod p (test reference).
pub fn negacyclic_mod(a: &[u64], b: &[u64], p: u64) -> Vec<u64> {
    let n = a.len();
    let mut out = vec![0u64; n];
    for i in 0..n {
        for j in 0..n {
            let t = a[i] * b[j] % p;
            let k = i + j;
            if k < n { out[k] = (out[k] + t) % p } else { out[k - n] = (out[k - n] + p - t) % p }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::swntt::{Engine, Prepared};

    fn lcg(s: &mut u64) -> u64 {
        *s = s.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        *s >> 17
    }

    #[test]
    fn cg_matches_inplace_order_and_inverts() {
        for &p in &PRIMES {
            for &n in &[8usize, 64, 2048] {
                let q = NttQ::new(p, n);
                let mut s = p ^ n as u64;
                let a: Vec<u64> = (0..n).map(|_| lcg(&mut s) % p).collect();
                // in-place Longa-Naehrig reference
                let mut r = a.clone();
                let (mut t, mut m) = (n, 1);
                while m < n {
                    t >>= 1;
                    for i in 0..m {
                        let w = q.psi_rev[m + i];
                        for j in 2 * i * t..2 * i * t + t {
                            let (u, v) = (r[j], r[j + t] * w % p);
                            r[j] = (u + v) % p;
                            r[j + t] = (u + p - v) % p;
                        }
                    }
                    m <<= 1;
                }
                let f = q.forward(&a);
                assert_eq!(f, r, "CG forward order differs from in-place, p={p} n={n}");
                let back = q.inverse_unscaled(&f);
                let want: Vec<u64> = a.iter().map(|&x| x * n as u64 % p).collect();
                assert_eq!(back, want, "inverse(forward(a)) != N a");
            }
        }
    }

    #[test]
    fn ext_product_matches_schoolbook() {
        for &p in &PRIMES {
            let n = 256;
            let q = NttQ::new(p, n);
            let mut s = 99 + p;
            let mut rnd = || (0..n).map(|_| lcg(&mut s) % p).collect::<Vec<u64>>();
            let d = [rnd(), rnd()];
            let b = [[rnd(), rnd()], [rnd(), rnd()]];
            let (_, _, out) = q.ext_product(&d, &b);
            for c in 0..2 {
                let want: Vec<u64> = negacyclic_mod(&d[0], &b[0][c], p).iter().zip(negacyclic_mod(&d[1], &b[1][c], p)).map(|(x, y)| (x + y) % p).collect();
                assert_eq!(out[c], want);
            }
        }
    }

    /// Links Stage 0 and Stage 1: per-residue NTT products equal the RNS model's exact product
    /// reduced mod each p_i, for digits and operands drawn as in the PBS.
    #[test]
    fn residues_match_rns_model_product() {
        let n = 2048;
        let eng = Engine::new(n);
        let mut s = 7u64;
        let q: u128 = PRIMES.iter().map(|&p| p as u128).product();
        let digits: Vec<Vec<i64>> = (0..2).map(|_| (0..n).map(|_| (lcg(&mut s) as i64 % (1 << 23)) - (1 << 22)).collect()).collect();
        let ops: Vec<Vec<i64>> = (0..4)
            .map(|_| (0..n).map(|_| { let x = (lcg(&mut s) as u128 * lcg(&mut s) as u128 % q) as i64; if x as u128 > q / 2 { x - q as i64 } else { x } }).collect())
            .collect();
        let prep: Vec<Prepared> = ops.iter().map(|o| eng.prepare(o)).collect();
        let exact = eng.mac(&digits, &[vec![&prep[0], &prep[1]], vec![&prep[2], &prep[3]]], 2);
        for &p in &PRIMES {
            let nq = NttQ::new(p, n);
            let m = |x: i64| (x as i128).rem_euclid(p as i128) as u64;
            let d = [digits[0].iter().map(|&x| m(x)).collect(), digits[1].iter().map(|&x| m(x)).collect()];
            let b = [[ops[0].iter().map(|&x| m(x)).collect(), ops[1].iter().map(|&x| m(x)).collect()],
                     [ops[2].iter().map(|&x| m(x)).collect(), ops[3].iter().map(|&x| m(x)).collect()]];
            let (_, _, out) = nq.ext_product(&d, &b);
            for c in 0..2 {
                let want: Vec<u64> = exact[c].iter().map(|&x| x.rem_euclid(p as i128) as u64).collect();
                assert_eq!(out[c], want, "p={p} c={c}");
            }
        }
    }
}
