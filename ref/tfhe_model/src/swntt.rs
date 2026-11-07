//! Exact integer negacyclic convolution engine (software only, not the hardware arithmetic).
//!
//! Computes sum_r D_r * T_rc in Z[X]/(X^N+1) EXACTLY as i128, for small digit polynomials D_r
//! (|d| <= 2^30) and i64 operands T_rc, by CRT over two ~2^62 NTT primes (product ~2^124, while
//! the worst-case magnitude is 2^(30+63+11+1) < 2^106 for two rows). The caller reduces the
//! exact result modulo whatever ring the modelled arithmetic lives in (2^64 or Q), so this engine
//! fixes no hardware choice; it only has to be exact, which `tests::conv_matches_schoolbook` checks.

pub const SW_PRIMES: [u64; 2] = [0x3fff_ffff_ffff_0001, 0x3fff_ffff_fffe_8001];
const SW_ROOTS_4096: [u64; 2] = [3710688476054411196, 2356062642078914529];

#[derive(Clone)]
pub struct Field {
    pub p: u64,
    pinv_neg: u64, // -p^{-1} mod 2^64
    r2: u64,       // 2^128 mod p
    psi_rev: Vec<u64>,     // Montgomery form psi^{bitrev(i)}
    psi_inv_rev: Vec<u64>, // Montgomery form psi^{-bitrev(i)}
    n_inv: u64,            // Montgomery form N^{-1}
}

#[inline(always)]
fn redc(t: u128, p: u64, pinv_neg: u64) -> u64 {
    let m = (t as u64).wrapping_mul(pinv_neg);
    let u = ((t + (m as u128) * (p as u128)) >> 64) as u64;
    if u >= p { u - p } else { u }
}

fn pow_mod(mut b: u64, mut e: u64, p: u64) -> u64 {
    let mut r = 1u64;
    b %= p;
    while e > 0 {
        if e & 1 == 1 {
            r = ((r as u128 * b as u128) % p as u128) as u64;
        }
        b = ((b as u128 * b as u128) % p as u128) as u64;
        e >>= 1;
    }
    r
}

fn bitrev(x: usize, bits: u32) -> usize {
    x.reverse_bits() >> (usize::BITS - bits)
}

impl Field {
    pub fn new(idx: usize, n: usize) -> Self {
        let p = SW_PRIMES[idx];
        assert!(n.is_power_of_two() && n <= 2048);
        let mut inv = 1u64; // Newton iteration for p^{-1} mod 2^64
        for _ in 0..7 {
            inv = inv.wrapping_mul(2u64.wrapping_sub(p.wrapping_mul(inv)));
        }
        let pinv_neg = inv.wrapping_neg();
        let r = ((1u128 << 64) % p as u128) as u64;
        let r2 = ((r as u128 * r as u128) % p as u128) as u64;
        // psi: primitive 2n-th root of unity.
        let psi = pow_mod(SW_ROOTS_4096[idx], (4096 / (2 * n)) as u64, p);
        let psi_inv = pow_mod(psi, p - 2, p);
        let bits = n.trailing_zeros();
        let to_m = |x: u64| ((x as u128 * r as u128) % p as u128) as u64;
        let psi_rev = (0..n).map(|i| to_m(pow_mod(psi, bitrev(i, bits) as u64, p))).collect();
        let psi_inv_rev = (0..n).map(|i| to_m(pow_mod(psi_inv, bitrev(i, bits) as u64, p))).collect();
        let n_inv = to_m(pow_mod(n as u64, p - 2, p));
        Field { p, pinv_neg, r2, psi_rev, psi_inv_rev, n_inv }
    }

    /// a * b_mont mod p (b in Montgomery form, a and result in normal form).
    #[inline(always)]
    pub fn mul(&self, a: u64, b_mont: u64) -> u64 {
        redc(a as u128 * b_mont as u128, self.p, self.pinv_neg)
    }

    pub fn to_mont(&self, a: u64) -> u64 {
        self.mul(a, self.r2)
    }

    #[inline(always)]
    fn add(&self, a: u64, b: u64) -> u64 {
        let s = a + b; // p < 2^62, no overflow
        if s >= self.p { s - self.p } else { s }
    }

    #[inline(always)]
    fn sub(&self, a: u64, b: u64) -> u64 {
        if a >= b { a - b } else { a + self.p - b }
    }

    pub fn from_i64(&self, x: i64) -> u64 {
        (x as i128).rem_euclid(self.p as i128) as u64
    }

    /// Negacyclic forward NTT (Cooley-Tukey, psi merged), natural in, bit-reversed out.
    pub fn forward(&self, a: &mut [u64]) {
        let n = a.len();
        let mut t = n;
        let mut m = 1;
        while m < n {
            t >>= 1;
            for i in 0..m {
                let s = self.psi_rev[m + i];
                let j1 = 2 * i * t;
                for j in j1..j1 + t {
                    let u = a[j];
                    let v = self.mul(a[j + t], s);
                    a[j] = self.add(u, v);
                    a[j + t] = self.sub(u, v);
                }
            }
            m <<= 1;
        }
    }

    /// Negacyclic inverse NTT (Gentleman-Sande), bit-reversed in, natural out, scaled by N^{-1}.
    pub fn inverse(&self, a: &mut [u64]) {
        let n = a.len();
        let mut t = 1;
        let mut m = n;
        while m > 1 {
            let h = m >> 1;
            let mut j1 = 0;
            for i in 0..h {
                let s = self.psi_inv_rev[h + i];
                for j in j1..j1 + t {
                    let u = a[j];
                    let v = a[j + t];
                    a[j] = self.add(u, v);
                    a[j + t] = self.mul(self.sub(u, v), s);
                }
                j1 += 2 * t;
            }
            t <<= 1;
            m = h;
        }
        for x in a.iter_mut() {
            *x = self.mul(*x, self.n_inv);
        }
    }
}

/// Two-prime engine. Operands are pre-transformed once (`prepare`), digits per call.
#[derive(Clone)]
pub struct Engine {
    pub n: usize,
    pub f: [Field; 2],
    p0_inv_mod_p1: u64, // Montgomery form of p0^{-1} mod p1
}

/// An operand polynomial in the transform domain of both primes, stored in Montgomery form.
pub type Prepared = [Vec<u64>; 2];

impl Engine {
    pub fn new(n: usize) -> Self {
        let f = [Field::new(0, n), Field::new(1, n)];
        let inv = pow_mod(SW_PRIMES[0] % SW_PRIMES[1], SW_PRIMES[1] - 2, SW_PRIMES[1]);
        let p0_inv_mod_p1 = f[1].to_mont(inv);
        Engine { n, f, p0_inv_mod_p1 }
    }

    pub fn prepare(&self, t: &[i64]) -> Prepared {
        let one = |k: usize| {
            let fk = &self.f[k];
            let mut v: Vec<u64> = t.iter().map(|&x| fk.from_i64(x)).collect();
            fk.forward(&mut v);
            v.iter().map(|&x| fk.to_mont(x)).collect()
        };
        [one(0), one(1)]
    }

    /// out[c] = sum_r digits[r] * ops[r][c], exact, as i128 per coefficient.
    pub fn mac(&self, digits: &[Vec<i64>], ops: &[Vec<&Prepared>], cols: usize) -> Vec<Vec<i128>> {
        let n = self.n;
        let mut res = vec![[vec![0u64; n], vec![0u64; n]]; cols];
        for k in 0..2 {
            let fk = &self.f[k];
            let dt: Vec<Vec<u64>> = digits
                .iter()
                .map(|d| {
                    let mut v: Vec<u64> = d.iter().map(|&x| fk.from_i64(x)).collect();
                    fk.forward(&mut v);
                    v
                })
                .collect();
            for c in 0..cols {
                let acc = &mut res[c][k];
                for (r, d) in dt.iter().enumerate() {
                    let op = &ops[r][c][k];
                    for j in 0..n {
                        acc[j] = fk.add(acc[j], fk.mul(d[j], op[j]));
                    }
                }
                fk.inverse(acc);
            }
        }
        let (p0, p1) = (SW_PRIMES[0] as i128, SW_PRIMES[1] as i128);
        let big = p0 * p1;
        res.iter()
            .map(|[r0, r1]| {
                (0..n)
                    .map(|j| {
                        // x = r0 + p0 * ((r1 - r0) * p0^{-1} mod p1), then centre in (-P/2, P/2].
                        let d = self.f[1].sub(r1[j], r0[j] % SW_PRIMES[1]);
                        let h = self.f[1].mul(d, self.p0_inv_mod_p1) as i128;
                        let x = r0[j] as i128 + p0 * h;
                        if x > big / 2 { x - big } else { x }
                    })
                    .collect()
            })
            .collect()
    }
}

/// Schoolbook negacyclic product, exact in i128 (test reference).
pub fn schoolbook(a: &[i64], b: &[i64]) -> Vec<i128> {
    let n = a.len();
    let mut out = vec![0i128; n];
    for i in 0..n {
        for j in 0..n {
            let p = a[i] as i128 * b[j] as i128;
            if i + j < n { out[i + j] += p } else { out[i + j - n] -= p }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Lcg(u64);
    impl Lcg {
        fn next(&mut self) -> u64 {
            self.0 = self.0.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            self.0 ^ (self.0 >> 29)
        }
    }

    #[test]
    fn conv_matches_schoolbook() {
        for &n in &[16usize, 256, 2048] {
            let e = Engine::new(n);
            let mut g = Lcg(n as u64);
            let d: Vec<Vec<i64>> = (0..2).map(|_| (0..n).map(|_| (g.next() as i64) >> 41).collect()).collect();
            // extreme operands included: i64::MIN and i64::MAX
            let t: Vec<Vec<i64>> = (0..2)
                .map(|r| (0..n).map(|j| if j == r { i64::MIN } else if j == 1 + r { i64::MAX } else { g.next() as i64 }).collect())
                .collect();
            let prep: Vec<Prepared> = t.iter().map(|x| e.prepare(x)).collect();
            let ops: Vec<Vec<&Prepared>> = prep.iter().map(|p| vec![p]).collect();
            let got = e.mac(&d, &ops, 1);
            let mut want = schoolbook(&d[0], &t[0]);
            for (w, x) in want.iter_mut().zip(schoolbook(&d[1], &t[1])) {
                *w += x;
            }
            assert_eq!(got[0], want, "n={n}");
        }
    }

    #[test]
    fn conv_worst_case_magnitude() {
        // all digits -2^22, all operands i64::MIN: |coef| = 2 * N * 2^22 * 2^63 = 2^97
        let n = 2048;
        let e = Engine::new(n);
        let d = vec![vec![-(1i64 << 22); n]; 2];
        let t = vec![i64::MIN; n];
        let p = e.prepare(&t);
        let got = e.mac(&d, &[vec![&p], vec![&p]], 1);
        let mut want = schoolbook(&d[0], &t);
        for w in want.iter_mut() {
            *w *= 2;
        }
        assert_eq!(got[0], want);
    }
}
