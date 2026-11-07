//! Test vectors for the Stage 2 engine blocks (ref/tfhe_model/src/engine.rs).
//!
//! dump_engine digits --count C [--seed S] --out FILE
//!   FILE: one line per sample, "y0 y1 y2 d" as hex: y_i in [0, p_i) (y-form residues), d the
//!   engine digit (Rns::digit through Engine::digit_y, F = FRAC_BITS) as 24-bit two's complement.
//!   A third of the samples sit next to digit rounding boundaries (x near (m + 1/2) Q / 2^23).
use std::fmt::Write as _;
use tfhe_model::engine::Engine;
use tfhe_model::ntt_q::{pow_mod, PRIMES};
use tfhe_model::tfhe::FRAC_BITS;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let get = |k: &str| args.iter().position(|a| a == k).map(|i| args[i + 1].clone());
    match args.get(1).map(|s| s.as_str()) {
        Some("digits") => {}
        Some("slice") => return slice(&get),
        Some("br") => return br(&get),
        Some("real") => return real(&get),
        Some("ks") => return ks(&get),
        _ => panic!("usage: dump_engine digits|slice|br|real|ks ..."),
    }
    let count: usize = get("--count").unwrap_or_else(|| "100000".into()).parse().unwrap();
    let seed: u64 = get("--seed").unwrap_or_else(|| "1".into()).parse().unwrap();
    let out = get("--out").expect("--out FILE");
    let eng = Engine::new(2048, FRAC_BITS, 23);
    let q: u128 = PRIMES.iter().map(|&p| p as u128).product();
    let yinv: Vec<u64> = PRIMES.iter().map(|&p| pow_mod(((q / p as u128) % p as u128) as u64, p - 2, p)).collect();
    let mut s = seed.wrapping_mul(0x9e3779b97f4a7c15) | 1;
    let mut rnd = || {
        s = s.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        s ^ (s >> 29)
    };
    let mut txt = String::new();
    for k in 0..count {
        let x: u64 = if k % 3 == 0 {
            // near a rounding boundary: x ~ (m + 1/2) Q / 2^23 + small offset
            let m = (rnd() % (1 << 23)) as u128;
            let base = ((2 * m + 1) * q) >> 24;
            let off = (rnd() % 64) as i64 - 32;
            ((base as i128 + off as i128).rem_euclid(q as i128)) as u64
        } else {
            (rnd() as u128 % q) as u64
        };
        let y: [u64; 3] = [0, 1, 2].map(|i| (x % PRIMES[i]) * yinv[i] % PRIMES[i]);
        let d = eng.digit_y(y, 23);
        writeln!(txt, "{:05x} {:05x} {:05x} {:06x}", y[0], y[1], y[2], (d as u64) & 0xff_ffff).unwrap();
    }
    std::fs::write(&out, txt).unwrap();
    println!("dump_engine digits: {count} samples (F = {FRAC_BITS}) -> {out}");
}

/// dump_engine slice --plog p --prime PR --slots BS --ops K [--seed S] --out DIR
///
/// Vectors for rtl/acc_slice.sv, one residue, block layout (lane q, time tau = position q*FR + tau;
/// a frame is FR = N/P lines, line = P lanes x 18 bits, lane 0 lowest):
///   lut.hex      : the y-form LUT body polynomial (FR lines)
///   ops.txt      : one op per line "type slot rot": type 1 INIT (rot = (2N - b~) mod 2N),
///                  0 CMUX (rot = a~), 2 EXTRACT (rot ignored); INIT for every slot first, then K
///                  CMUX ops on random slots, then EXTRACT for every slot
///   o.hex        : for each CMUX op, the O_0 frame then the O_1 frame fed back to accumulate
///   diff.hex     : for each CMUX op, the expected diff frames rot(ACC, a) - ACC, poly 0 then 1
///   extract.hex  : for each EXTRACT op, the frame of the extracted mask (out[0] = A[0],
///                  out[j] = -A[N-j]) in block layout, then one line holding body[0] in lane 0
fn slice(get: &dyn Fn(&str) -> Option<String>) {
    let plog: u32 = get("--plog").unwrap_or_else(|| "5".into()).parse().unwrap();
    let pr: u64 = get("--prime").unwrap_or_else(|| "249857".into()).parse().unwrap();
    let bs: usize = get("--slots").unwrap_or_else(|| "4".into()).parse().unwrap();
    let k: usize = get("--ops").unwrap_or_else(|| "24".into()).parse().unwrap();
    let seed: u64 = get("--seed").unwrap_or_else(|| "1".into()).parse().unwrap();
    let out = std::path::PathBuf::from(get("--out").expect("--out DIR"));
    std::fs::create_dir_all(&out).unwrap();
    let n = 2048usize;
    let pp = 1usize << plog;
    let fr = n / pp;
    let mut st = seed.wrapping_mul(0x2545f4914f6cdd1d) | 1;
    let mut rnd = move || {
        st = st.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        st >> 17
    };
    let rot = |poly: &[u64], e: usize| -> Vec<u64> {
        let mut o = vec![0u64; n];
        for (j, &v) in poly.iter().enumerate() {
            let t = (j + e) % (2 * n);
            if t < n { o[t] = v } else { o[t - n] = (pr - v) % pr }
        }
        o
    };
    // lanes packed as 18-bit fields (lane 0 lowest), big-endian hex of the P*18-bit word
    let pack = |lanes: &[u64]| -> String {
        let total = 18 * lanes.len();
        let bit = |b: usize| -> u8 { ((lanes[b / 18] >> (b % 18)) & 1) as u8 };
        (0..total.div_ceil(4)).rev().map(|d| {
            let nib = (0..4).fold(0u8, |acc, k| acc | if 4 * d + k < total { bit(4 * d + k) << k } else { 0 });
            char::from_digit(nib as u32, 16).unwrap()
        }).collect()
    };
    let frame = |poly: &[u64]| -> Vec<String> {
        (0..fr).map(|tau| pack(&(0..pp).map(|q| poly[q * fr + tau]).collect::<Vec<_>>())).collect()
    };
    let lut: Vec<u64> = (0..n).map(|_| rnd() % pr).collect();
    let mut acc: Vec<[Vec<u64>; 2]> = vec![[vec![0; n], vec![0; n]]; bs];
    let (mut ops, mut ov, mut dv, mut ev) = (String::new(), vec![], vec![], vec![]);
    let mut init_body: Vec<String> = vec![];
    for c in 0..bs {
        let b = (rnd() % (2 * n as u64)) as usize;
        let r = (2 * n - b) % (2 * n);
        writeln!(ops, "1 {c} {r}").unwrap();
        acc[c] = [vec![0; n], rot(&lut, r)];
        init_body.extend(frame(&acc[c][1]));
    }
    std::fs::write(out.join("acc_init.hex"), init_body.join("\n") + "\n").unwrap();
    for _ in 0..k {
        let c = (rnd() % bs as u64) as usize;
        let a = (rnd() % (2 * n as u64)) as usize;
        writeln!(ops, "0 {c} {a}").unwrap();
        for poly in 0..2 {
            let r = rot(&acc[c][poly], a);
            let d: Vec<u64> = (0..n).map(|j| (r[j] + pr - acc[c][poly][j]) % pr).collect();
            dv.extend(frame(&d));
        }
        for poly in 0..2 {
            let o: Vec<u64> = (0..n).map(|_| rnd() % pr).collect();
            ov.extend(frame(&o));
            for j in 0..n {
                acc[c][poly][j] = (acc[c][poly][j] + o[j]) % pr;
            }
        }
    }
    for c in 0..bs {
        writeln!(ops, "2 {c} 0").unwrap();
        let a = &acc[c][0];
        let ext: Vec<u64> = (0..n).map(|j| if j == 0 { a[0] } else { (pr - a[n - j]) % pr }).collect();
        ev.extend(frame(&ext));
        ev.push(pack(&(0..pp).map(|q| if q == 0 { acc[c][1][0] } else { 0 }).collect::<Vec<_>>()));
    }
    std::fs::write(out.join("lut.hex"), frame(&lut).join("\n") + "\n").unwrap();
    std::fs::write(out.join("ops.txt"), ops).unwrap();
    for (name, v) in [("o.hex", ov), ("diff.hex", dv), ("extract.hex", ev)] {
        std::fs::write(out.join(name), v.join("\n") + "\n").unwrap();
    }
    println!("dump_engine slice: P={pp} p={pr} slots={bs} ops={k} -> {}", out.display());
}

/// dump_engine br --plog p --slots B --n NC [--red mont|table] [--seed S] --out DIR
///
/// Vectors for rtl/br_core.sv: a whole blind rotation of B ciphertext slots with NC CMuxes on
/// random data (equality with Engine::blind_rotate is an identity of the arithmetic).
///   lut_p<pr>.hex : y-form phi(LUT) residues, block layout, FR lines of P x 18 bits
///   ms.txt        : per slot one line: NC masks then the body, decimal, each in [0, 2N)
///   op_p<pr>.hex  : per CMux index FR lines of {B'_11, B'_10, B'_01, B'_00} x P lanes (stored form)
///                   in forward-output layout: the host-prepared BSK (engine form)
///   ext_p<pr>.hex : per slot the EXTRACT frame (sample-extracted mask, y-form) then one line with
///                   body[0] in lane 0
///   out.hex       : per slot the 2049 u64 outputs after psi (hex, one per line)
fn br(get: &dyn Fn(&str) -> Option<String>) {
    let plog: u32 = get("--plog").unwrap_or_else(|| "5".into()).parse().unwrap();
    let bs: usize = get("--slots").unwrap_or_else(|| "8".into()).parse().unwrap();
    let nc: usize = get("--n").unwrap_or_else(|| "8".into()).parse().unwrap();
    let mont = get("--red").map(|r| r == "mont").unwrap_or(true);
    let seed: u64 = get("--seed").unwrap_or_else(|| "1".into()).parse().unwrap();
    let out = std::path::PathBuf::from(get("--out").expect("--out DIR"));
    std::fs::create_dir_all(&out).unwrap();
    let n = 2048usize;
    let mut st = seed.wrapping_mul(0x9e3779b97f4a7c15) | 1;
    let mut rnd = move || {
        st = st.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        st ^ (st >> 29)
    };
    let eng = Engine::new(n, FRAC_BITS, 23);
    let lut: Vec<u64> = (0..n).map(|_| rnd()).collect();
    let ggsws: Vec<_> = (0..nc)
        .map(|_| {
            let g: [[Vec<u64>; 2]; 2] = [0, 1].map(|_| [0, 1].map(|_| (0..n).map(|_| rnd()).collect()));
            eng.prepare_ggsw(&g)
        })
        .collect();
    let ms_list: Vec<Vec<u64>> = (0..bs).map(|_| (0..=nc).map(|_| rnd() % (2 * n as u64)).collect()).collect();
    write_br(&out, plog, mont, &eng, &lut, &ggsws, &ms_list);
    println!("dump_engine br: P={} slots={bs} n={nc} mont={mont} -> {}", 1 << plog, out.display());
}

/// Writes the br_core vector set (see `br`) for the given LUT, prepared GGSWs and ms lists.
fn write_br(out: &std::path::Path, plog: u32, mont: bool, eng: &Engine, lut: &[u64], ggsws: &[tfhe_model::engine::GgswQ], ms_list: &[Vec<u64>]) {
    use tfhe_model::ntt_pipe::Pipe;
    use tfhe_model::tfhe::Params;
    let n = 2048usize;
    let pp = 1usize << plog;
    let fr = n / pp;
    let nc = ggsws.len();
    let pack = |lanes: &[u64]| -> String {
        let total = 18 * lanes.len();
        let bit = |b: usize| -> u8 { ((lanes[b / 18] >> (b % 18)) & 1) as u8 };
        (0..total.div_ceil(4)).rev().map(|d| {
            let nib = (0..4).fold(0u8, |acc, k| acc | if 4 * d + k < total { bit(4 * d + k) << k } else { 0 });
            char::from_digit(nib as u32, 16).unwrap()
        }).collect()
    };
    let block = |poly: &[u64]| -> Vec<String> {
        (0..fr).map(|tau| pack(&(0..pp).map(|q| poly[q * fr + tau]).collect::<Vec<_>>())).collect()
    };
    let stored = |w: u64, p: u64| -> u64 {
        let v = if mont { (w as u128 * (1u128 << 18) % p as u128) as u64 } else { w };
        let s = if v > p / 2 { v as i64 - p as i64 } else { v as i64 };
        (s as u64) & 0x3ffff
    };
    let p = Params { n: nc, k: 1, big_n: n, pbs_base_log: 23, pbs_level: 1, ks_base_log: 4, ks_level: 4, ks_out_bits: 32, delta_log2: 59 };
    let fpos = Pipe::forward(11, plog).output_positions();
    let mut ms_txt = String::new();
    let mut outs = String::new();
    let mut ext: Vec<Vec<String>> = vec![vec![]; 3];
    for ms in ms_list {
        writeln!(ms_txt, "{}", ms.iter().map(|x| x.to_string()).collect::<Vec<_>>().join(" ")).unwrap();
        let (o, tr) = eng.blind_rotate(&p, ggsws, lut, ms, 0);
        for w in &o {
            writeln!(outs, "{w:016x}").unwrap();
        }
        for i in 0..3 {
            let pr = PRIMES[i];
            let a = &tr.final_acc[i][0];
            let e: Vec<u64> = (0..n).map(|j| if j == 0 { a[0] } else { (pr - a[n - j]) % pr }).collect();
            ext[i].extend(block(&e));
            ext[i].push(pack(&(0..pp).map(|q| if q == 0 { tr.final_acc[i][1][0] } else { 0 }).collect::<Vec<_>>()));
        }
    }
    std::fs::write(out.join("ms.txt"), ms_txt).unwrap();
    std::fs::write(out.join("out.hex"), outs).unwrap();
    for i in 0..3 {
        let pr = PRIMES[i];
        let lut_y: Vec<u64> = lut.iter().map(|&t| { let x = eng.rns.phi(t); (x % pr) * eng.yinv[i] % pr }).collect();
        std::fs::write(out.join(format!("lut_p{pr}.hex")), block(&lut_y).join("\n") + "\n").unwrap();
        let mut op = Vec::new();
        for g in ggsws {
            for tau in 0..fr {
                let mut lanes = Vec::with_capacity(4 * pp);
                for (r, c) in [(0, 0), (0, 1), (1, 0), (1, 1)] {
                    lanes.extend((0..pp).map(|q| stored(g[i][r][c][fpos[tau * pp + q]], pr)));
                }
                op.push(pack(&lanes));
            }
        }
        std::fs::write(out.join(format!("op_p{pr}.hex")), op.join("\n") + "\n").unwrap();
        std::fs::write(out.join(format!("ext_p{pr}.hex")), ext[i].join("\n") + "\n").unwrap();
    }
}

/// dump_engine real --keys DIR --plog p --slots B --first K [--red mont] --out OUT
/// The br_core vector set for real tfhe-rs keys: BSK (bsk.u64) in engine form, the LUT (lut.u64),
/// and the modulus-switched inputs of ciphertexts K..K+B-1 (ref_ms.u32, tfhe-rs's own KS -> MS,
/// bit-identical to ours). out.hex is what the RTL must produce; tfhe-rs decrypts it.
fn real(get: &dyn Fn(&str) -> Option<String>) {
    use tfhe_model::read_words;
    let dir = std::path::PathBuf::from(get("--keys").expect("--keys DIR"));
    let plog: u32 = get("--plog").unwrap_or_else(|| "5".into()).parse().unwrap();
    let bs: usize = get("--slots").unwrap_or_else(|| "8".into()).parse().unwrap();
    let first: usize = get("--first").unwrap_or_else(|| "0".into()).parse().unwrap();
    let mont = get("--red").map(|r| r == "mont").unwrap_or(true);
    let out = std::path::PathBuf::from(get("--out").expect("--out DIR"));
    std::fs::create_dir_all(&out).unwrap();
    let n = 2048usize;
    let nc = 918usize;
    let eng = Engine::new(n, FRAC_BITS, 23);
    let bsk = read_words(&dir.join("bsk.u64"), 8);
    assert_eq!(bsk.len(), nc * 4 * n, "bsk.u64 size");
    let ggsws: Vec<_> = (0..nc)
        .map(|i| {
            let g: [[Vec<u64>; 2]; 2] = [0, 1].map(|r| [0, 1].map(|c| bsk[((i * 2 + r) * 2 + c) * n..][..n].to_vec()));
            eng.prepare_ggsw(&g)
        })
        .collect();
    let lut = read_words(&dir.join("lut.u64"), 8);
    let ms_all = read_words(&dir.join("ref_ms.u32"), 4);
    let ms_list: Vec<Vec<u64>> = (first..first + bs).map(|c| ms_all[c * (nc + 1)..(c + 1) * (nc + 1)].to_vec()).collect();
    write_br(&out, plog, mont, &eng, &lut, &ggsws, &ms_list);
    let msgs = read_words(&dir.join("msg_in.u8"), 1);
    std::fs::write(out.join("msg.u8"), msgs[first..first + bs].iter().map(|&m| m as u8).collect::<Vec<u8>>()).unwrap();
    println!("dump_engine real: keys {} cts {}..{} P={} -> {}", dir.display(), first, first + bs, 1 << plog, out.display());
}

/// dump_engine ks --keys DIR --lanes L --count C --out OUT
/// Vectors for rtl/ks32.sv straight from tfhe-rs (the oracle's own KS32 -> MS outputs):
///   ksk.hex  : row r = i*4 + stored level, W = ceil(919/L) words of L x 32 bits (lane 0 lowest)
///   ct.hex   : C input LWEs (2049 u64 each, hex, one per line)
///   ks.hex   : tfhe-rs KS outputs (919 u32 per ct);  ms.hex: tfhe-rs MS outputs (919 per ct)
fn ks(get: &dyn Fn(&str) -> Option<String>) {
    use tfhe_model::read_words;
    let dir = std::path::PathBuf::from(get("--keys").expect("--keys DIR"));
    let l: usize = get("--lanes").unwrap_or_else(|| "16".into()).parse().unwrap();
    let c: usize = get("--count").unwrap_or_else(|| "4".into()).parse().unwrap();
    let out = std::path::PathBuf::from(get("--out").expect("--out DIR"));
    std::fs::create_dir_all(&out).unwrap();
    let (nin, nout) = (2048usize, 919usize);
    let w = nout.div_ceil(l);
    let ksk = read_words(&dir.join("ksk.u32"), 4);
    assert_eq!(ksk.len(), nin * 4 * nout);
    let mut txt = String::with_capacity(nin * 4 * w * (l * 8 + 1));
    for r in 0..nin * 4 {
        for k in 0..w {
            for lane in (0..l).rev() {
                let o = k * l + lane;
                let v = if o < nout { ksk[r * nout + o] } else { 0 };
                write!(txt, "{v:08x}").unwrap();
            }
            txt.push('\n');
        }
    }
    std::fs::write(out.join("ksk.hex"), txt).unwrap();
    let cts = read_words(&dir.join("lwe_in.u64"), 8);
    let kso = read_words(&dir.join("ref_ks_out.u32"), 4);
    let mso = read_words(&dir.join("ref_ms.u32"), 4);
    let lines = |v: &[u64], fmt: usize| -> String { v.iter().map(|x| format!("{:0width$x}\n", x, width = fmt)).collect() };
    std::fs::write(out.join("ct.hex"), lines(&cts[..c * 2049], 16)).unwrap();
    std::fs::write(out.join("ks.hex"), lines(&kso[..c * nout], 8)).unwrap();
    std::fs::write(out.join("ms.hex"), lines(&mso[..c * nout], 3)).unwrap();
    println!("dump_engine ks: L={l} W={w} cts={c} -> {}", out.display());
}
