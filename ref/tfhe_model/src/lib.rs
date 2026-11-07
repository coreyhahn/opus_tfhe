//! opus_tfhe exact-integer reference model. See tfhe.rs for the algorithm, swntt.rs for the exact
//! software convolution used to evaluate it, docs/FORMATS.md for the file layouts.

pub mod engine;
pub mod ntt_pipe;
pub mod ntt_q;
pub mod swntt;
pub mod tfhe;

use std::path::Path;

pub fn read_words(path: &Path, bytes_per: usize) -> Vec<u64> {
    let raw = std::fs::read(path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
    assert_eq!(raw.len() % bytes_per, 0, "{}: size not a multiple of {bytes_per}", path.display());
    raw.chunks_exact(bytes_per)
        .map(|c| {
            let mut b = [0u8; 8];
            b[..bytes_per].copy_from_slice(c);
            u64::from_le_bytes(b)
        })
        .collect()
}

pub fn write_words(path: &Path, words: &[u64], bytes_per: usize) {
    let mut raw = Vec::with_capacity(words.len() * bytes_per);
    for w in words {
        raw.extend_from_slice(&w.to_le_bytes()[..bytes_per]);
    }
    std::fs::write(path, raw).unwrap_or_else(|e| panic!("write {}: {e}", path.display()));
}

/// Summary statistics of signed errors.
#[derive(Debug, Clone, serde::Serialize)]
pub struct Stats {
    pub count: usize,
    pub mean: f64,
    pub std: f64,
    pub log2_std: f64,
    pub max_abs: f64,
}

pub fn stats(xs: &[f64]) -> Stats {
    let n = xs.len() as f64;
    let mean = xs.iter().sum::<f64>() / n;
    let var = xs.iter().map(|x| (x - mean) * (x - mean)).sum::<f64>() / (n - 1.0).max(1.0);
    let max_abs = xs.iter().fold(0.0f64, |m, x| m.max(x.abs()));
    Stats { count: xs.len(), mean, std: var.sqrt(), log2_std: var.sqrt().log2(), max_abs }
}

/// Complementary error function, Numerical Recipes `erfcc` (relative error < 1.2e-7 everywhere,
/// including deep tails, which is what an implied p-fail needs).
pub fn erfc(x: f64) -> f64 {
    let z = x.abs();
    let t = 1.0 / (1.0 + 0.5 * z);
    let poly = -z * z - 1.26551223
        + t * (1.00002368
            + t * (0.37409196
                + t * (0.09678418
                    + t * (-0.18628806
                        + t * (0.27886807 + t * (-1.13520398 + t * (1.48851587 + t * (-0.82215223 + t * 0.17087277))))))));
    let r = t * poly.exp();
    if x >= 0.0 { r } else { 2.0 - r }
}

/// log2 P(failure) for a Gaussian error with the given mean/std that fails outside [lo, hi].
pub fn log2_gauss_fail(mean: f64, std: f64, lo: f64, hi: f64) -> f64 {
    let s2 = std * std::f64::consts::SQRT_2;
    let p = 0.5 * erfc((hi - mean) / s2) + 0.5 * erfc((mean - lo) / s2);
    p.log2()
}
