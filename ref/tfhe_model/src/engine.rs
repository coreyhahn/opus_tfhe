//! Hardware-structured blind rotation (Stage 2 target), RNS arithmetic of docs/PARAMS.md.
//!
//! Same mathematics as `tfhe::blind_rotate_extract` with `Arith::Rns`, organised as the engine
//! computes it, so every block boundary of the RTL has a bit-exact reference:
//! * the accumulator is kept per residue in **y-form**: acc_y[i] = acc mod p_i * (Q/p_i)^{-1} mod p_i.
//!   Rotation, subtraction and accumulation are linear, so they commute with that scaling. The
//!   approximate-CRT digit and the output map psi take y directly: no multiply by the inverse;
//! * the BSK operands are prepared per residue as N^{-1} (Q/p_i)^{-1} NTT(phi(bsk) mod p_i)
//!   (the host's job), so ext_product outputs come out in y-form;
//! * the external product is three per-residue NttQ products (the RTL's xpipe1).
//!   `tests::engine_equals_rns_model` checks the whole thing against `tfhe.rs`.

use crate::ntt_q::{pow_mod, NttQ, PRIMES};
use crate::tfhe::{Params, Rns};

pub struct Engine {
    pub rns: Rns,
    pub nq: Vec<NttQ>,
    pub yinv: Vec<u64>, // (Q/p_i)^{-1} mod p_i
}

/// One GGSW of the BSK prepared for the engine: [residue][row][col] polynomials in NTT position
/// order, values N^{-1} (Q/p_i)^{-1} NTT(phi(b) mod p_i) mod p_i.
pub type GgswQ = Vec<[[Vec<u64>; 2]; 2]>;

/// Per-CMux trace for RTL debugging: digits (signed) and the y-form accumulator after the CMux.
pub struct Trace {
    pub digits: Vec<[Vec<i64>; 2]>,
    pub acc_y: Vec<Vec<[Vec<u64>; 2]>>, // [cmux][residue][poly]
    pub final_acc: Vec<[Vec<u64>; 2]>, // [residue][poly], y-form, before sample extraction
}

impl Engine {
    pub fn new(n: usize, frac_bits: u32, base_log: u32) -> Self {
        let rns = Rns::new(PRIMES.to_vec(), frac_bits, base_log);
        let q = rns.q;
        let yinv = PRIMES.iter().map(|&p| pow_mod(((q / p as u128) % p as u128) as u64, p - 2, p)).collect();
        let nq = PRIMES.iter().map(|&p| NttQ::new(p, n)).collect();
        Engine { rns, nq, yinv }
    }

    fn to_y(&self, x_mod_q: u64) -> [u64; 3] {
        [0, 1, 2].map(|i| (x_mod_q % PRIMES[i]) * self.yinv[i] % PRIMES[i])
    }

    /// Reconstruct x mod Q from y-form residues (exact CRT; used for the digit reference only).
    fn from_y(&self, y: [u64; 3]) -> u64 {
        let q = self.rns.q;
        let mut s: u128 = 0;
        for i in 0..3 {
            s = (s + y[i] as u128 * (q / PRIMES[i] as u128)) % q;
        }
        s as u64
    }

    /// Host-side preparation of one GGSW (rows r, cols c, standard-domain u64 polynomials).
    pub fn prepare_ggsw(&self, ggsw: &[[Vec<u64>; 2]; 2]) -> GgswQ {
        (0..3)
            .map(|i| {
                let p = PRIMES[i];
                let scale = self.nq[i].n_inv() * self.yinv[i] % p;
                [0, 1].map(|r| {
                    [0, 1].map(|c| {
                        let x: Vec<u64> = ggsw[r][c].iter().map(|&t| self.rns.phi(t) % p).collect();
                        self.nq[i].forward(&x).iter().map(|&v| v * scale % p).collect()
                    })
                })
            })
            .collect()
    }

    /// The engine's digit: approximate CRT on the y-form residues of x (same formula as Rns::digit).
    pub fn digit_y(&self, y: [u64; 3], base_log: u32) -> i64 {
        self.rns.digit(self.from_y(y), base_log)
    }

    /// Blind rotation + sample extraction for one ciphertext. `ms` = n masks then body in [0, 2N).
    pub fn blind_rotate(&self, p: &Params, bsk: &[GgswQ], lut: &[u64], ms: &[u64], keep_trace: usize) -> (Vec<u64>, Trace) {
        let nn = p.big_n;
        let two_n = 2 * nn;
        let rot = |poly: &Vec<u64>, e: usize, pr: u64| -> Vec<u64> {
            let mut out = vec![0u64; nn];
            for (j, &v) in poly.iter().enumerate() {
                let t = (j + e) % two_n;
                if t < nn { out[t] = v } else { out[t - nn] = (pr - v) % pr }
            }
            out
        };
        // ACC = (0, X^{-b~} LUT), y-form per residue
        let body = ms[p.n] as usize;
        let lut_y: Vec<[u64; 3]> = lut.iter().map(|&t| self.to_y(self.rns.phi(t))).collect();
        let mut acc: Vec<[Vec<u64>; 2]> = (0..3)
            .map(|i| [vec![0u64; nn], rot(&lut_y.iter().map(|y| y[i]).collect(), (two_n - body) % two_n, PRIMES[i])])
            .collect();
        let mut trace = Trace { digits: vec![], acc_y: vec![], final_acc: vec![] };
        for (k, ggsw) in bsk.iter().enumerate() {
            let a = ms[k] as usize;
            if a != 0 {
                // digits from rot(ACC) - ACC
                let mut d = [vec![0i64; nn], vec![0i64; nn]];
                let diff: Vec<[Vec<u64>; 2]> = (0..3)
                    .map(|i| {
                        let pr = PRIMES[i];
                        [0, 1].map(|c| {
                            let r = rot(&acc[i][c], a, pr);
                            (0..nn).map(|j| (r[j] + pr - acc[i][c][j]) % pr).collect()
                        })
                    })
                    .collect();
                for c in 0..2 {
                    for j in 0..nn {
                        d[c][j] = self.digit_y([diff[0][c][j], diff[1][c][j], diff[2][c][j]], p.pbs_base_log);
                    }
                }
                for i in 0..3 {
                    let pr = PRIMES[i];
                    let dr: [Vec<u64>; 2] = [0, 1].map(|c| d[c].iter().map(|&x| x.rem_euclid(pr as i64) as u64).collect());
                    // O_c = INTT(sum_r NTT(D_r) * B'_rc): operands already prepared (scaled, NTT domain)
                    let dh = [self.nq[i].forward(&dr[0]), self.nq[i].forward(&dr[1])];
                    for c in 0..2 {
                        let mac: Vec<u64> = (0..nn).map(|j| (dh[0][j] * ggsw[i][0][c][j] + dh[1][j] * ggsw[i][1][c][j]) % pr).collect();
                        let o = self.nq[i].inverse_unscaled(&mac);
                        for j in 0..nn {
                            acc[i][c][j] = (acc[i][c][j] + o[j]) % pr;
                        }
                    }
                }
                if k < keep_trace {
                    trace.digits.push(d);
                }
            }
            if k < keep_trace {
                trace.acc_y.push(acc.clone());
            }
        }
        trace.final_acc = acc.clone();
        // sample extraction of coefficient 0, then psi (approximate CRT from y-form)
        let ext = |yv: [u64; 3]| self.rns.psi(self.from_y(yv));
        let neg = |i: usize, v: u64| (PRIMES[i] - v) % PRIMES[i];
        let mut out = vec![0u64; nn + 1];
        out[0] = ext([acc[0][0][0], acc[1][0][0], acc[2][0][0]]);
        for j in 1..nn {
            out[j] = ext([0, 1, 2].map(|i| neg(i, acc[i][0][nn - j])));
        }
        out[nn] = ext([acc[0][1][0], acc[1][1][0], acc[2][1][0]]);
        (out, trace)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::swntt::Engine as SwEngine;
    use crate::tfhe::{blind_rotate_extract, prepare_bsk, Arith};

    /// The hardware-structured rotation equals the Stage 0 RNS model on random inputs (any GGSW
    /// values: equality is an identity of the arithmetic, not of the cryptography).
    #[test]
    fn engine_equals_rns_model() {
        let p = Params { n: 24, k: 1, big_n: 2048, pbs_base_log: 23, pbs_level: 1, ks_base_log: 4, ks_level: 4, ks_out_bits: 32, delta_log2: 59 };
        let mut s = 0x1234_5678u64;
        let mut r64 = || {
            s = s.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            s ^ (s >> 31)
        };
        let bsk_raw: Vec<u64> = (0..p.n * 4 * 2048).map(|_| r64()).collect();
        let lut: Vec<u64> = (0..2048).map(|_| r64()).collect();
        let ms: Vec<u64> = (0..=p.n).map(|i| if i == 3 { 0 } else { r64() % 4096 }).collect();
        let arith = Arith::Rns(Rns::new(PRIMES.to_vec(), 32, 23));
        let sw = SwEngine::new(2048);
        let prep = prepare_bsk(&p, &arith, &sw, &bsk_raw);
        let want = blind_rotate_extract(&p, &arith, &sw, &prep, &lut, &ms);
        let eng = Engine::new(2048, 32, 23);
        let ggsws: Vec<GgswQ> = (0..p.n)
            .map(|i| {
                let g: [[Vec<u64>; 2]; 2] = [0, 1].map(|r| [0, 1].map(|c| bsk_raw[((i * 2 + r) * 2 + c) * 2048..][..2048].to_vec()));
                eng.prepare_ggsw(&g)
            })
            .collect();
        let (got, _) = eng.blind_rotate(&p, &ggsws, &lut, &ms, 0);
        assert_eq!(got, want);
    }
}
