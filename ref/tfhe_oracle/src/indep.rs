//! Independent plain-integer re-implementation of the maths in docs/FORMATS.md.
//!
//! NOTHING in this file calls tfhe-rs. It reads the flat files written by `gen`
//! and recomputes, from the FORMATS.md rules only:
//!   1. decryption of lwe_in under glwe_sk          (encoding, key order)
//!   2. the LUT body polynomial                      (box / half-box / rotate)
//!   3. the keyswitch, bit-exact vs ref_ks_out        (decomposer + KSK layout)
//!   4. the centered-mean modulus switch, bit-exact vs ref_ms
//!   5. GGSW layout/sign of bsk.u64 by decrypting rows under glwe_sk
//!   6. decryption of ref_pbs_out vs the table        (sample-extract key order)
//!   7. optional (--exact-pbs K): an exact integer blind rotation + sample
//!      extraction from ref_ms and bsk.u64, compared with ref_pbs_out
//!      (tfhe-rs uses an f64 FFT, so this measures the FFT's deviation).

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::time::Instant;

use rayon::prelude::*;

use crate::fileio::*;
use crate::load_meta;

const DELTA_LOG2: u32 = 59;

/// Signed gadget decomposition (FORMATS.md section 3).
/// Returns digits indexed by decomposition level j = 1..=l at position j-1
/// (j = 1 is the most significant digit, weight 2^64 / B^1).
pub fn decompose(a: u64, beta: usize, l: usize) -> Vec<i64> {
    let rep = beta * l;
    let b: i64 = 1 << beta;
    // round-half-up of the top rep bits
    let mut x = a >> (64 - rep - 1);
    let rb = x & 1;
    x = (x + 1) >> 1;
    x &= (1u64 << rep) - 1;
    let half = 1u64 << (rep - 1);
    let mut s: i64 = x as i64;
    if x > half || (x == half && rb == 1) {
        s -= 1i64 << rep;
    }
    let mut digits = vec![0i64; l];
    for j in (1..=l).rev() {
        let mut d = s & (b - 1);
        s >>= beta; // arithmetic
        if d > b / 2 || (d == b / 2 && (s & (b - 1)) >= b / 2) {
            d -= b;
            s += 1;
        }
        digits[j - 1] = d;
    }
    digits
}

fn wmask(w: u32) -> u64 {
    if w == 64 { u64::MAX } else { (1u64 << w) - 1 }
}

/// Keyswitch big (u64, dim kN) -> small (w bits, dim n). ksk is [kN][l][n+1] (w-bit words in u64).
fn keyswitch(ct: &[u64], ksk: &[u64], n: usize, beta: usize, l: usize, w: u32) -> Vec<u64> {
    let big = ct.len() - 1;
    let m = wmask(w);
    let mut out = vec![0u64; n + 1];
    let b = ct[big];
    out[n] = if w == 64 {
        b
    } else {
        // closest representable on the top w bits (round half up), then drop the low 64-w bits
        (((b >> (64 - w - 1)) + 1) >> 1) & m
    };
    for i in 0..big {
        let d = decompose(ct[i], beta, l);
        for j in 1..=l {
            let t = l - j; // stored level index for decomposition level j
            let dj = d[j - 1] as u64; // two's complement, wraps
            if dj == 0 {
                continue;
            }
            let row = &ksk[(i * l + t) * (n + 1)..(i * l + t + 1) * (n + 1)];
            for (o, &kv) in out.iter_mut().zip(row) {
                *o = o.wrapping_sub(dj.wrapping_mul(kv)) & m;
            }
        }
    }
    out
}

/// Centered-mean modulus switch from w bits to log2(2N) bits (FORMATS.md section 4).
fn centered_ms(ct: &[u64], w: u32, log_2n: u32) -> Vec<u32> {
    let n = ct.len() - 1;
    let m = wmask(w);
    let sh = w - log_2n;
    let rnd = |a: u64| -> u64 { ((a as u128 + (1u128 << (sh - 1))) >> sh) as u64 & ((1u64 << log_2n) - 1) };
    let mut e_sum: i128 = 0; // exact sum of signed rounding errors
    let mut d_sum: i64 = 0; // (#negative odd errors) - (#positive odd errors)
    let mut out = Vec::with_capacity(n + 1);
    for &a in &ct[..n] {
        let r = rnd(a);
        out.push(r as u32);
        let err_u = (r << sh).wrapping_sub(a) & m;
        // interpret as signed w-bit
        let err: i64 = if w == 64 { err_u as i64 } else { ((err_u << (64 - w)) as i64) >> (64 - w) };
        e_sum += err as i128;
        if err % 2 != 0 {
            d_sum += if err < 0 { 1 } else { -1 };
        }
    }
    // tfhe-rs's correction: E/2 exactly when E even, else (E + sign(D)) / 2
    let corr: i128 = if e_sum % 2 == 0 {
        e_sum / 2
    } else {
        assert!(d_sum % 2 != 0);
        (e_sum + d_sum.signum() as i128) / 2
    };
    let corr_u = (corr as u128 as u64) & m;
    let b = ct[n];
    let half_case = 1u64 << (sh - 1);
    let b2 = b.wrapping_add(corr_u).wrapping_sub(half_case) & m;
    out.push(rnd(b2) as u32);
    out
}

/// Negacyclic product accumulate: out += d * p  (mod X^N + 1, mod 2^64).
fn negacyclic_mac(out: &mut [u64], d: &[i64], p: &[u64]) {
    let nn = out.len();
    for j in 0..nn {
        let dj = d[j] as u64;
        if dj == 0 {
            continue;
        }
        let (lo, hi) = out.split_at_mut(j);
        // terms with j + l < N
        for (o, &pv) in hi.iter_mut().zip(&p[..nn - j]) {
            *o = o.wrapping_add(dj.wrapping_mul(pv));
        }
        // terms with j + l >= N wrap with a minus sign
        for (o, &pv) in lo.iter_mut().zip(&p[nn - j..]) {
            *o = o.wrapping_sub(dj.wrapping_mul(pv));
        }
    }
}

/// Multiply a polynomial by X^e (e in [0, 2N)) negacyclically.
fn monomial_mul(p: &[u64], e: usize) -> Vec<u64> {
    let nn = p.len();
    let mut out = vec![0u64; nn];
    for (j, &v) in p.iter().enumerate() {
        let t = (j + e) % (2 * nn);
        if t < nn {
            out[t] = v;
        } else {
            out[t - nn] = v.wrapping_neg();
        }
    }
    out
}

/// Exact integer PBS from a modulus-switched LWE (FORMATS.md sections 5-6).
fn exact_pbs(ms: &[u32], lut: &[u64], bsk: &[u64], n: usize, k: usize, nn: usize, beta: usize, l: usize) -> Vec<u64> {
    let two_n = 2 * nn;
    let b = ms[n] as usize;
    // ACC = (0,...,0, LUT) * X^{-b}
    let mut acc: Vec<Vec<u64>> = vec![vec![0u64; nn]; k + 1];
    acc[k] = monomial_mul(lut, (two_n - b) % two_n);
    let ggsw_len = l * (k + 1) * (k + 1) * nn;
    for i in 0..n {
        let a = ms[i] as usize;
        if a == 0 {
            continue;
        }
        // ct1 = ACC * X^a - ACC
        let ct1: Vec<Vec<u64>> = acc
            .iter()
            .map(|p| monomial_mul(p, a).iter().zip(p).map(|(x, y)| x.wrapping_sub(*y)).collect())
            .collect();
        // digits[r][t] = polynomial of the digit for stored level index t of component r
        let ggsw = &bsk[i * ggsw_len..(i + 1) * ggsw_len];
        for r in 0..=k {
            let mut digs = vec![vec![0i64; nn]; l];
            for (c, &x) in ct1[r].iter().enumerate() {
                let d = decompose(x, beta, l);
                for j in 1..=l {
                    digs[l - j][c] = d[j - 1];
                }
            }
            for t in 0..l {
                for c in 0..=k {
                    let off = ((t * (k + 1) + r) * (k + 1) + c) * nn;
                    negacyclic_mac(&mut acc[c], &digs[t], &ggsw[off..off + nn]);
                }
            }
        }
    }
    // sample extract coefficient 0
    let mut out = Vec::with_capacity(k * nn + 1);
    for r in 0..k {
        out.push(acc[r][0]);
        for c in 1..nn {
            out.push(acc[r][nn - c].wrapping_neg());
        }
    }
    out.push(acc[k][0]);
    out
}

fn glwe_phase(row: &[u64], s: &[u64], k: usize, nn: usize) -> Vec<u64> {
    // phase = B - sum_r A_r * S_r  (negacyclic)
    let mut ph = row[k * nn..(k + 1) * nn].to_vec();
    for r in 0..k {
        let sr: Vec<i64> = s[r * nn..(r + 1) * nn].iter().map(|&x| -(x as i64)).collect();
        negacyclic_mac(&mut ph, &sr, &row[r * nn..(r + 1) * nn]);
    }
    ph
}

fn lwe_phase(ct: &[u64], s: &[u64]) -> u64 {
    let n = s.len();
    let mut ph = ct[n];
    for i in 0..n {
        ph = ph.wrapping_sub(ct[i].wrapping_mul(s[i]));
    }
    ph
}

fn decode(phase: u64) -> u64 {
    (((phase as u128 + (1u128 << (DELTA_LOG2 - 1))) >> DELTA_LOG2) as u64) % 32
}

pub fn cmd_verify_format(args: &BTreeMap<String, String>) {
    let dir = PathBuf::from(args.get("dir").expect("--dir"));
    let exact_k: usize = args.get("exact-pbs").map(|s| s.parse().unwrap()).unwrap_or(0);
    let (j, meta) = load_meta(&dir);
    let p = meta.p;
    let (n, k, nn) = (p.n, p.k, p.big_n);
    let big = k * nn;
    let w = j["ks_output_modulus_log2"].as_u64().unwrap() as u32;
    let log_2n = (2 * nn).ilog2();
    let c = meta.count;
    let t0 = Instant::now();

    let lwe_sk = read_u64(&dir.join("lwe_sk.u64"));
    let glwe_sk = read_u64(&dir.join("glwe_sk.u64"));
    let msgs = read_u8(&dir.join("msg_in.u8"));
    let lwe_in = read_u64(&dir.join("lwe_in.u64"));
    let (ksk, ref_ks): (Vec<u64>, Vec<u64>) = if w == 32 {
        (
            read_u32(&dir.join("ksk.u32")).iter().map(|&x| x as u64).collect(),
            read_u32(&dir.join("ref_ks_out.u32")).iter().map(|&x| x as u64).collect(),
        )
    } else {
        (read_u64(&dir.join("ksk.u64")), read_u64(&dir.join("ref_ks_out.u64")))
    };
    let ref_ms = read_u32(&dir.join("ref_ms.u32"));
    let lut = read_u64(&dir.join("lut.u64"));
    let bsk = read_u64(&dir.join("bsk.u64"));
    let ref_pbs = read_u64(&dir.join("ref_pbs_out.u64"));
    assert_eq!(ksk.len(), big * p.ks_level * (n + 1));
    assert_eq!(bsk.len(), n * p.pbs_level * (k + 1) * (k + 1) * nn);
    assert_eq!(lwe_in.len(), c * (big + 1));

    // 1. input decryption under the big key (glwe_sk flattened)
    let bad_in = (0..c)
        .filter(|&i| decode(lwe_phase(&lwe_in[i * (big + 1)..(i + 1) * (big + 1)], &glwe_sk)) != msgs[i] as u64)
        .count();
    println!("[1] lwe_in decrypts to msg_in under glwe_sk: {} / {} mismatches", bad_in, c);
    assert_eq!(bad_in, 0);

    // 2. LUT
    let p_space = (p.msg_mod * p.carry_mod) as usize;
    let box_size = nn / p_space;
    let mut my_lut = vec![0u64; nn];
    for x in 0..p_space {
        for v in &mut my_lut[x * box_size..(x + 1) * box_size] {
            *v = meta.table[x] << DELTA_LOG2;
        }
    }
    for v in &mut my_lut[..box_size / 2] {
        *v = v.wrapping_neg();
    }
    my_lut.rotate_left(box_size / 2);
    println!("[2] LUT body recomputed from table: {}", if my_lut == lut { "bit-exact" } else { "MISMATCH" });
    assert_eq!(my_lut, lut);

    // 3+4. KS and MS, bit-exact
    let res: Vec<(bool, bool)> = (0..c)
        .into_par_iter()
        .map(|i| {
            let ct = &lwe_in[i * (big + 1)..(i + 1) * (big + 1)];
            let ks = keyswitch(ct, &ksk, n, p.ks_base_log, p.ks_level, w);
            let ms = centered_ms(&ks, w, log_2n);
            let ks_ok = ks.as_slice() == &ref_ks[i * (n + 1)..(i + 1) * (n + 1)];
            // MS is checked from the REFERENCE KS output, so a KS bug cannot mask an MS bug
            let ms_ref_in = centered_ms(&ref_ks[i * (n + 1)..(i + 1) * (n + 1)], w, log_2n);
            let ms_ok = ms_ref_in.as_slice() == &ref_ms[i * (n + 1)..(i + 1) * (n + 1)] && ms == ms_ref_in;
            (ks_ok, ms_ok)
        })
        .collect();
    let ks_bad: Vec<usize> = res.iter().enumerate().filter(|(_, r)| !r.0).map(|(i, _)| i).collect();
    let ms_bad: Vec<usize> = res.iter().enumerate().filter(|(_, r)| !r.1).map(|(i, _)| i).collect();
    println!("[3] keyswitch (w={w}) bit-exact vs ref_ks_out: {} / {} mismatches {:?}", ks_bad.len(), c, &ks_bad[..ks_bad.len().min(10)]);
    println!("[4] centered MS (-> 2^{log_2n}) bit-exact vs ref_ms: {} / {} mismatches {:?}", ms_bad.len(), c, &ms_bad[..ms_bad.len().min(10)]);

    // 5. BSK layout: decrypt every row of a few GGSWs
    let beta = p.pbs_base_log;
    let l = p.pbs_level;
    let ggsw_len = l * (k + 1) * (k + 1) * nn;
    let mut worst: i64 = 0;
    let picks: Vec<usize> = vec![0, 1, 2, 3, n / 2, n - 1];
    for &i in &picks {
        let s_i = lwe_sk[i];
        for t in 0..l {
            let jlev = l - t; // decomposition level of stored index t
            let g = (s_i as u64).wrapping_mul(1u64 << (64 - beta * jlev)); // s_i * q / B^j
            for r in 0..=k {
                let off = i * ggsw_len + (t * (k + 1) + r) * (k + 1) * nn;
                let ph = glwe_phase(&bsk[off..off + (k + 1) * nn], &glwe_sk, k, nn);
                let expect: Vec<u64> = if r < k {
                    // -s_i * g * S_r
                    glwe_sk[r * nn..(r + 1) * nn].iter().map(|&s| (g.wrapping_mul(s)).wrapping_neg()).collect()
                } else {
                    let mut e = vec![0u64; nn];
                    e[0] = g;
                    e
                };
                for (a, b) in ph.iter().zip(&expect) {
                    worst = worst.max((a.wrapping_sub(*b) as i64).abs());
                }
            }
        }
    }
    println!(
        "[5] bsk.u64 GGSW rows decrypt to (-s_i*q/B^j*S_r | +s_i*q/B^j) for i in {:?}: max |noise| = {} (= 2^{:.2}; TUniform bound 2^{})",
        picks, worst, (worst as f64).log2(), j["glwe_noise"]["bound_log2"]
    );
    assert!(worst <= 1i64 << j["glwe_noise"]["bound_log2"].as_u64().unwrap());

    // 6. PBS output decryption (independent of tfhe-rs decrypt)
    let bad_pbs = (0..c)
        .filter(|&i| decode(lwe_phase(&ref_pbs[i * (big + 1)..(i + 1) * (big + 1)], &glwe_sk)) != meta.table[msgs[i] as usize])
        .count();
    println!("[6] ref_pbs_out decrypts to f(msg) under glwe_sk: {} / {} mismatches", bad_pbs, c);

    // 7. exact integer PBS
    if exact_k > 0 {
        let t = Instant::now();
        let kk = exact_k.min(c);
        let diffs: Vec<(usize, i64, u64, bool, i64)> = (0..kk)
            .into_par_iter()
            .map(|i| {
                let ms = &ref_ms[i * (n + 1)..(i + 1) * (n + 1)];
                let out = exact_pbs(ms, &lut, &bsk, n, k, nn, beta, l);
                let r = &ref_pbs[i * (big + 1)..(i + 1) * (big + 1)];
                let ndiff = out.iter().zip(r).filter(|(a, b)| a != b).count();
                let maxd = out.iter().zip(r).map(|(a, b)| (a.wrapping_sub(*b) as i64).abs()).max().unwrap();
                let ph = lwe_phase(&out, &glwe_sk);
                let ok = decode(ph) == meta.table[msgs[i] as usize];
                let err = ph.wrapping_sub(meta.table[msgs[i] as usize] << DELTA_LOG2) as i64;
                (ndiff, maxd, 0, ok, err)
            })
            .collect();
        let tot: usize = diffs.iter().map(|d| d.0).sum();
        let maxd = diffs.iter().map(|d| d.1).max().unwrap();
        let ok = diffs.iter().filter(|d| d.3).count();
        let errs: Vec<f64> = diffs.iter().map(|d| d.4 as f64).collect();
        let sd = (errs.iter().map(|e| e * e).sum::<f64>() / errs.len() as f64).sqrt();
        println!(
            "[7] exact-integer PBS on {kk} ciphertexts ({:.1}s): {} of {} coefficients differ from tfhe-rs (f64 FFT); max |diff| = {} (2^{:.2}); exact PBS decrypts correctly {}/{}; exact-PBS rms err 2^{:.2}",
            t.elapsed().as_secs_f64(), tot, kk * (big + 1), maxd, (maxd as f64).log2(), ok, kk, sd.log2()
        );
    }

    // 8. blind-rotation probes (few non-zero mask entries): exact BR vs tfhe-rs FFT BR
    let mut probe_ok = true;
    if dir.join("probe_ms.u32").exists() {
        let pms = read_u32(&dir.join("probe_ms.u32"));
        let pbr = read_u64(&dir.join("probe_br_out.u64"));
        let np = pms.len() / (n + 1);
        let res: Vec<String> = (0..np)
            .into_par_iter()
            .map(|i| {
                let ms = &pms[i * (n + 1)..(i + 1) * (n + 1)];
                let nz = ms[..n].iter().filter(|&&x| x != 0).count();
                let out = exact_pbs(ms, &lut, &bsk, n, k, nn, beta, l);
                let r = &pbr[i * (big + 1)..(i + 1) * (big + 1)];
                let nd = out.iter().zip(r).filter(|(a, b)| a != b).count();
                let md = out.iter().zip(r).map(|(a, b)| (a.wrapping_sub(*b) as i64).unsigned_abs()).max().unwrap();
                let dph = (lwe_phase(&out, &glwe_sk).wrapping_sub(lwe_phase(r, &glwe_sk)) as i64).unsigned_abs();
                format!("    probe {i}: nonzero mask = {nz:4}  coeffs differing {nd:5}/{}  max|diff| = 2^{:.2}  |phase diff| = 2^{:.2}",
                        big + 1, (md.max(1) as f64).log2(), (dph.max(1) as f64).log2())
            })
            .collect();
        println!("[8] blind-rotation probes, exact integer BR (from FORMATS.md) vs tfhe-rs f64-FFT BR:");
        for s in &res {
            println!("{s}");
        }
        // a convention error would give |diff| ~ 2^63 already for a single CMux
        let first = &pbr[..big + 1];
        let out0 = exact_pbs(&pms[..n + 1], &lut, &bsk, n, k, nn, beta, l);
        let md0 = out0.iter().zip(first).map(|(a, b)| (a.wrapping_sub(*b) as i64).unsigned_abs()).max().unwrap();
        probe_ok = md0 < (1u64 << 40);
    }

    let pass = probe_ok && ks_bad.is_empty() && ms_bad.is_empty() && bad_pbs == 0;
    println!("verify-format {}: {} ({:.1}s)", dir.display(), if pass { "PASS" } else { "FAIL" }, t0.elapsed().as_secs_f64());
    if !pass {
        std::process::exit(1);
    }
}
