//! Data layout of the streaming (feedforward) NTT pipeline, rtl/ntt_pipe.sv (Stage 1b).
//!
//! The pipeline carries P = 2^p coefficients per cycle; one polynomial is a frame of N/P cycles.
//! A coefficient's position (n = log2 N bits) is spread over the p path bits and the n-p bits of
//! the frame-local time. The layout says where every position bit currently lives:
//!
//! * input of the forward pipeline: block per path, position = path * N/P + time
//!   (path bit c = position bit n-p+c, time bit t = position bit t);
//! * a stage pairs positions differing in its span bit k (the in-place algorithm of
//!   ntt_q.rs: forward Cooley-Tukey k = n-1-s, inverse Gentleman-Sande k = r);
//!   - if bit k is a path bit c, the P/2 butterflies pair paths differing in path bit c;
//!   - if bit k is time bit t, a shuffle first swaps path bit 0 with time bit t (delays L = 2^t
//!     and 2L on a path pair), then the butterflies pair paths differing in path bit 0;
//! * the butterfly writes the lower position (bit k = 0) to the path with the pair bit 0.
//!
//! Butterfly unit u of a stage handles the path pair (a, a | 1<<c) where a is the u-th path, in
//! increasing order, whose bit c is 0. Its twiddle at frame-local time tau (after the shuffle) is
//! that of the in-place algorithm for the pair's lower position. The forward output layout is the
//! inverse's input layout; after the inverse the layout is block per path again.

use crate::ntt_q::NttQ;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Loc {
    Path(u32),
    Time(u32),
}

#[derive(Clone, Copy, Debug)]
pub struct Stage {
    pub span_bit: u32,
    pub shuffle_time_bit: Option<u32>,
    pub pair_path_bit: u32,
}

#[derive(Clone, Debug)]
pub struct Pipe {
    pub n: u32,
    pub p: u32,
    pub inverse: bool,
    pub stages: Vec<Stage>,
    pub layouts: Vec<Vec<Loc>>, // layouts[i] = where each position bit is before stage i (len = stages + 1)
}

pub fn block_layout(n: u32, p: u32) -> Vec<Loc> {
    (0..n).map(|b| if b >= n - p { Loc::Path(b - (n - p)) } else { Loc::Time(b) }).collect()
}

impl Pipe {
    pub fn new(n: u32, p: u32, inverse: bool, input: Vec<Loc>) -> Self {
        let mut layout = input;
        let mut stages = Vec::new();
        let mut layouts = vec![layout.clone()];
        for i in 0..n {
            let k = if inverse { i } else { n - 1 - i };
            let st = match layout[k as usize] {
                Loc::Path(c) => Stage { span_bit: k, shuffle_time_bit: None, pair_path_bit: c },
                Loc::Time(t) => {
                    let x = layout.iter().position(|&l| l == Loc::Path(0)).unwrap();
                    layout[x] = Loc::Time(t);
                    layout[k as usize] = Loc::Path(0);
                    Stage { span_bit: k, shuffle_time_bit: Some(t), pair_path_bit: 0 }
                }
            };
            stages.push(st);
            layouts.push(layout.clone());
        }
        Pipe { n, p, inverse, stages, layouts }
    }

    pub fn forward(n: u32, p: u32) -> Self {
        Self::new(n, p, false, block_layout(n, p))
    }

    pub fn inverse_of(fwd: &Pipe) -> Self {
        Self::new(fwd.n, fwd.p, true, fwd.layouts.last().unwrap().clone())
    }

    /// Position held at (path, time) under layout `l`.
    pub fn position(l: &[Loc], path: usize, time: usize) -> usize {
        l.iter().enumerate().fold(0, |acc, (b, loc)| {
            let bit = match *loc {
                Loc::Path(c) => (path >> c) & 1,
                Loc::Time(t) => (time >> t) & 1,
            };
            acc | (bit << b)
        })
    }

    /// The u-th path whose bit c is 0.
    pub fn unit_path(u: usize, c: u32) -> usize {
        let low = u & ((1 << c) - 1);
        let high = u >> c;
        (high << (c + 1)) | low
    }

    /// Twiddle (plain value mod p) of unit u of stage i at frame-local time tau.
    pub fn twiddle(&self, q: &NttQ, i: usize, u: usize, tau: usize) -> u64 {
        let st = self.stages[i];
        let a = Self::unit_path(u, st.pair_path_bit);
        let j = Self::position(&self.layouts[i + 1], a, tau); // lower position: span bit 0 on path a
        debug_assert_eq!((j >> st.span_bit) & 1, 0);
        if !self.inverse {
            // in-place CT, stage s = i: psi_rev[2^s + (j >> (n - s))]
            let s = i as u32;
            q.psi_rev[(1usize << s) + (j >> (self.n - s))]
        } else {
            // in-place GS, stage r = i: t = 2^r, h = N >> (r+1), block j >> (r+1)
            let r = i as u32;
            let h = (1usize << self.n) >> (r + 1);
            q.psi_inv_rev[h + (j >> (r + 1))]
        }
    }

    /// Frame (time-major: frame[tau * P + path]) -> positions under the final layout.
    pub fn output_positions(&self) -> Vec<usize> {
        let pp = 1usize << self.p;
        let frame = 1usize << (self.n - self.p);
        let l = self.layouts.last().unwrap();
        (0..frame).flat_map(|tau| (0..pp).map(move |path| Self::position(l, path, tau))).collect()
    }

    /// Functional evaluation of the pipeline: applies each stage's butterflies on the pairs the
    /// hardware forms, in position space. Must equal the in-place transform.
    pub fn eval(&self, q: &NttQ, a: &[u64]) -> Vec<u64> {
        let pm = q.p;
        let pp = 1usize << self.p;
        let frame = 1usize << (self.n - self.p);
        let mut x = a.to_vec();
        for (i, st) in self.stages.iter().enumerate() {
            let l = &self.layouts[i + 1];
            let mut y = x.clone();
            for u in 0..pp / 2 {
                let pa = Self::unit_path(u, st.pair_path_bit);
                let pb = pa | (1 << st.pair_path_bit);
                for tau in 0..frame {
                    let (ja, jb) = (Self::position(l, pa, tau), Self::position(l, pb, tau));
                    assert_eq!(jb, ja + (1 << st.span_bit));
                    let w = self.twiddle(q, i, u, tau);
                    let (uu, vv) = (x[ja], x[jb]);
                    if !self.inverse {
                        let t = w * vv % pm;
                        y[ja] = (uu + t) % pm;
                        y[jb] = (uu + pm - t) % pm;
                    } else {
                        y[ja] = (uu + vv) % pm;
                        y[jb] = (uu + pm - vv) % pm * w % pm;
                    }
                }
            }
            x = y;
        }
        x
    }
}

/// Closed form of the stage plan, as rtl/ntt_pipe.sv computes it at elaboration:
/// (shuffle time bit or None, butterfly pair path bit). Checked against `Pipe::new` in tests.
pub fn closed_form_stage(n: u32, p: u32, inverse: bool, i: u32) -> (Option<u32>, u32) {
    if !inverse {
        if i < p { (None, p - 1 - i) } else { (Some(n - 1 - i), 0) }
    } else if i == 0 {
        (None, 0)
    } else if i <= n - p {
        (Some(i - 1), 0)
    } else {
        (None, i - (n - p))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ntt_q::{NttQ, PRIMES};

    #[test]
    fn closed_form_plan_matches() {
        for p in 1..=6u32 {
            let fwd = Pipe::forward(11, p);
            let inv = Pipe::inverse_of(&fwd);
            for (pipe, inverse) in [(&fwd, false), (&inv, true)] {
                for (i, st) in pipe.stages.iter().enumerate() {
                    assert_eq!(closed_form_stage(11, p, inverse, i as u32), (st.shuffle_time_bit, st.pair_path_bit), "p={p} inv={inverse} i={i}");
                }
            }
        }
    }

    #[test]
    fn pipeline_equals_in_place_transform() {
        for &p_log in &[1u32, 2, 3, 4, 5] {
            for &prime in &PRIMES[..2] {
                let n = 11;
                let q = NttQ::new(prime, 1 << n);
                let mut s = 5u64 + p_log as u64;
                let a: Vec<u64> = (0..1 << n)
                    .map(|_| {
                        s = s.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
                        (s >> 20) % prime
                    })
                    .collect();
                let fwd = Pipe::forward(n, p_log);
                assert_eq!(fwd.eval(&q, &a), q.forward(&a), "forward P=2^{p_log}");
                let inv = Pipe::inverse_of(&fwd);
                assert_eq!(inv.eval(&q, &a), q.inverse_unscaled(&a), "inverse P=2^{p_log}");
                assert_eq!(inv.layouts.last().unwrap(), &block_layout(n, p_log), "inverse restores block layout");
            }
        }
    }
}
