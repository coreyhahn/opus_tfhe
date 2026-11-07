//! `tfhe_model run`: KS -> MS -> PBS over a batch of ciphertexts from an oracle key directory.
//!
//! tfhe_model run --keys DIR --arith exact64|rns:P1,P2,..[:F] --lut sq3|mod4|id --out PREFIX   (F default 28)
//!                [--input FILE.u64] [--in-msgs FILE.u8] [--scale W] [--count C]
//!                [--ref-ks FILE] [--ref-ms FILE] [--ref-pbs FILE]
//!
//! Defaults: input = DIR/lwe_in.u64, in-msgs = DIR/msg_in.u8, refs = DIR/ref_{ks_out,ms,pbs_out}
//! when the input is DIR/lwe_in.u64. Writes PREFIX.ks.u{32,64}, PREFIX.ms.u32, PREFIX.pbs.u64,
//! PREFIX.json (bit-exactness against the refs, noise statistics measured with the test keys).

use rayon::prelude::*;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::Instant;
use tfhe_model::swntt::Engine;
use tfhe_model::tfhe::*;
use tfhe_model::*;

fn lut_fn(name: &str) -> fn(u64) -> u64 {
    match name {
        "sq3" => |x| (x * x + 3) % 16,
        "mod4" => |x| x % 4,
        "id" => |x| x,
        _ => panic!("unknown lut {name}"),
    }
}

fn parse_arith(s: &str, base_log: u32) -> Arith {
    if s == "exact64" {
        return Arith::Exact64;
    }
    let rest = s.strip_prefix("rns:").expect("--arith exact64 | rns:P1,P2,..[:F]");
    let mut it = rest.split(':');
    let primes = it.next().unwrap().split(',').map(|p| p.parse().unwrap()).collect();
    let f = it.next().map(|f| f.parse().unwrap()).unwrap_or(FRAC_BITS);
    Arith::Rns(Rns::new(primes, f, base_log))
}

fn signed_mod(x: u64, bits: u32) -> f64 {
    if bits == 64 {
        x as i64 as f64
    } else {
        let m = 1u64 << bits;
        let x = x & (m - 1);
        if x >= m / 2 { x as f64 - m as f64 } else { x as f64 }
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    assert!(args.len() > 1 && args[1] == "run", "usage: tfhe_model run --keys DIR ...");
    let mut opt: HashMap<String, String> = HashMap::new();
    let mut i = 2;
    while i < args.len() {
        opt.insert(args[i].trim_start_matches("--").to_string(), args[i + 1].clone());
        i += 2;
    }
    let dir = PathBuf::from(&opt["keys"]);
    let meta: Value = serde_json::from_slice(&std::fs::read(dir.join("meta.json")).unwrap()).unwrap();
    let g = |k: &str| meta[k].as_u64().unwrap_or_else(|| panic!("meta.json lacks {k}"));
    let p = Params {
        n: g("n") as usize,
        k: g("k") as usize,
        big_n: g("N") as usize,
        pbs_base_log: g("pbs_base_log") as u32,
        pbs_level: g("pbs_level") as usize,
        ks_base_log: g("ks_base_log") as u32,
        ks_level: g("ks_level") as usize,
        ks_out_bits: g("ks_output_modulus_log2") as u32,
        delta_log2: g("delta_log2") as u32,
    };
    let msg_space = (g("message_modulus") * g("carry_modulus")) as usize;
    let kn = p.k * p.big_n;
    let ks_bytes = (p.ks_out_bits / 8) as usize;
    let arith = parse_arith(&opt["arith"], p.pbs_base_log);
    let lut_name = opt.get("lut").cloned().unwrap_or_else(|| "sq3".into());
    let f = lut_fn(&lut_name);
    let out_prefix = opt["out"].clone();

    let default_input = dir.join("lwe_in.u64");
    let input_path = opt.get("input").map(PathBuf::from).unwrap_or(default_input.clone());
    let is_default_input = input_path == default_input;
    let mut cts = read_words(&input_path, 8);
    if let Some(w) = opt.get("scale") {
        let w: u64 = w.parse().unwrap();
        cts.iter_mut().for_each(|x| *x = x.wrapping_mul(w));
    }
    let msgs: Vec<u64> = read_words(&opt.get("in-msgs").map(PathBuf::from).unwrap_or(dir.join("msg_in.u8")), 1);
    let mut count = cts.len() / (kn + 1);
    if let Some(c) = opt.get("count") {
        count = count.min(c.parse().unwrap());
    }
    let ref_path = |key: &str, default: &str| -> Option<PathBuf> {
        opt.get(key).map(PathBuf::from).or_else(|| if is_default_input { Some(dir.join(default)) } else { None })
    };
    let ks_ext = if p.ks_out_bits == 32 { "u32" } else { "u64" };

    // LUT: generated here, cross-checked against the oracle's when it was built for the same f.
    let lut = make_lut(&p, &f, msg_space);
    let mut lut_match = Value::Null;
    if meta["lut"]["name"].as_str() == Some(lut_name.as_str()) {
        let oracle_lut = read_words(&dir.join("lut.u64"), 8);
        lut_match = json!(oracle_lut == lut);
        assert_eq!(oracle_lut, lut, "model LUT differs from tfhe-rs LUT");
    }

    let ksk_words = read_words(&dir.join(format!("ksk.{ks_ext}")), ks_bytes);
    let lwe_sk = read_words(&dir.join("lwe_sk.u64"), 8);
    let glwe_sk = read_words(&dir.join("glwe_sk.u64"), 8);
    let ref_ks = ref_path("ref-ks", &format!("ref_ks_out.{ks_ext}")).map(|f| read_words(&f, ks_bytes));
    let ref_ms = ref_path("ref-ms", "ref_ms.u32").map(|f| read_words(&f, 4));
    let ref_pbs = ref_path("ref-pbs", "ref_pbs_out.u64").map(|f| read_words(&f, 8));

    // KSK level order (docs/FORMATS.md §3.2): stored index 0 holds the least significant level, so
    // decomposition level j (1 = most significant) lives at stored index ks_level - j. Where a
    // tfhe-rs reference exists the first ciphertext must agree, else stop: never guess an order.
    let level_order: Vec<usize> = (0..p.ks_level).map(|j1| p.ks_level - 1 - j1).collect();
    let ksk = Ksk { words: &ksk_words, stored_level_for: level_order.clone() };
    if let Some(rk) = &ref_ks {
        assert_eq!(keyswitch(&p, &ksk, &cts[..kn + 1]), rk[..p.n + 1], "KS disagrees with tfhe-rs on ciphertext 0");
    }

    let t0 = Instant::now();
    let eng = Engine::new(p.big_n);
    let bsk_raw = read_words(&dir.join("bsk.u64"), 8);
    let bsk = prepare_bsk(&p, &arith, &eng, &bsk_raw);
    drop(bsk_raw);
    let t_prep = t0.elapsed().as_secs_f64();

    let t1 = Instant::now();
    let results: Vec<(Vec<u64>, Vec<u64>, Vec<u64>)> = (0..count)
        .into_par_iter()
        .map(|c| {
            let ct = &cts[c * (kn + 1)..(c + 1) * (kn + 1)];
            let ks = keyswitch(&p, &ksk, ct);
            let ms = modulus_switch_centered(&p, &ks);
            let out = blind_rotate_extract(&p, &arith, &eng, &bsk, &lut, &ms);
            (ks, ms, out)
        })
        .collect();
    let t_run = t1.elapsed().as_secs_f64();

    let flat = |sel: fn(&(Vec<u64>, Vec<u64>, Vec<u64>)) -> &Vec<u64>| -> Vec<u64> { results.iter().flat_map(|r| sel(r).iter().copied()).collect() };
    let ks_all = flat(|r| &r.0);
    let ms_all = flat(|r| &r.1);
    let pbs_all = flat(|r| &r.2);
    write_words(Path::new(&format!("{out_prefix}.ks.{ks_ext}")), &ks_all, ks_bytes);
    write_words(Path::new(&format!("{out_prefix}.ms.u32")), &ms_all, 4);
    write_words(Path::new(&format!("{out_prefix}.pbs.u64")), &pbs_all, 8);

    let cmp = |mine: &[u64], reference: &Option<Vec<u64>>, width: usize| -> Value {
        match reference {
            None => Value::Null,
            Some(r) => {
                let bad: Vec<usize> = (0..count).filter(|&c| mine[c * width..(c + 1) * width] != r[c * width..(c + 1) * width]).collect();
                json!({"compared": count, "mismatching_ciphertexts": bad.len(), "first_mismatches": &bad[..bad.len().min(10)]})
            }
        }
    };

    // Noise, measured with the test secret keys.
    let lg2n = p.log2_2n();
    let mut ks_err = Vec::new();
    let mut ms_err = Vec::new();
    let mut pbs_err = Vec::new();
    let mut fails = Vec::new();
    let mut diff_ref = Vec::new();
    for c in 0..count {
        let m = msgs[c];
        let (ks, ms, out) = &results[c];
        let w = p.ks_out_bits;
        let mut ph = ks[p.n];
        for j in 0..p.n {
            ph = ph.wrapping_sub(ks[j].wrapping_mul(lwe_sk[j]));
        }
        let ideal = m.wrapping_mul(1u64 << (p.delta_log2 - (64 - w)));
        ks_err.push(signed_mod(ph.wrapping_sub(ideal), w));
        let mut phm = ms[p.n] as i64;
        for j in 0..p.n {
            phm -= (ms[j] * lwe_sk[j]) as i64;
        }
        let ideal_ms = (m << (p.delta_log2 + lg2n - 64)) as i64;
        ms_err.push(signed_mod((phm - ideal_ms) as u64, lg2n));
        let mut po = out[kn];
        for j in 0..kn {
            po = po.wrapping_sub(out[j].wrapping_mul(glwe_sk[j]));
        }
        let want = f(m % msg_space as u64).wrapping_mul(1u64 << p.delta_log2);
        let e = po.wrapping_sub(want) as i64;
        pbs_err.push(e as f64);
        // decryption: round to the nearest multiple of Delta, compare (padding bit included)
        let dec = (po.wrapping_add(1u64 << (p.delta_log2 - 1)) >> p.delta_log2) % (2 * msg_space as u64);
        if dec != f(m % msg_space as u64) {
            fails.push(c);
        }
        if let Some(r) = &ref_pbs {
            // phase difference to tfhe-rs's own output on the same input (ciphertexts differ: a
            // single flipped digit rounding swaps in another random GGSW row; phases must agree)
            let rc = &r[c * (kn + 1)..(c + 1) * (kn + 1)];
            let mut pr = rc[kn];
            for j in 0..kn {
                pr = pr.wrapping_sub(rc[j].wrapping_mul(glwe_sk[j]));
            }
            diff_ref.push(po.wrapping_sub(pr) as i64 as f64);
        }
    }
    let ms_stats = stats(&ms_err);
    // box of the message is [-N/msg_space/... ]: in 2N units a message occupies 2N/(2*msg_space)
    let half_box = (2 * p.big_n / (2 * msg_space)) as f64 / 2.0;
    let report = json!({
        "arith": arith.name(),
        "keys": dir.display().to_string(),
        "input": input_path.display().to_string(),
        "scale": opt.get("scale"),
        "lut": lut_name,
        "lut_matches_tfhe_rs": lut_match,
        "count": count,
        "ksk_stored_level_for": level_order,
        "seconds_prepare_bsk": t_prep,
        "seconds_run": t_run,
        "ks_vs_tfhe_rs": cmp(&ks_all, &ref_ks, p.n + 1),
        "ms_vs_tfhe_rs": cmp(&ms_all, &ref_ms, p.n + 1),
        "pbs_bit_equal_to_tfhe_rs": cmp(&pbs_all, &ref_pbs, kn + 1),
        "pbs_phase_minus_tfhe_rs_phase": if diff_ref.is_empty() { Value::Null } else { json!(stats(&diff_ref)) },
        "ks_phase_error_mod_2^w": stats(&ks_err),
        "ms_phase_error_units_of_1/2N": ms_stats,
        "ms_implied_log2_pfail_gaussian": log2_gauss_fail(ms_stats.mean, ms_stats.std, -half_box - 0.5, half_box - 0.5),
        "pbs_output_error_mod_2^64": stats(&pbs_err),
        "decrypt_failures_model_keys": fails.len(),
        "failed_indices": &fails[..fails.len().min(20)],
    });
    let txt = serde_json::to_string_pretty(&report).unwrap();
    std::fs::write(format!("{out_prefix}.json"), &txt).unwrap();
    println!("{txt}");
}
