//! tfhe_oracle: tfhe-rs 1.8.2 linked as an oracle for the opus_tfhe engine.
//!
//! Subcommands:
//!   gen            seeded keys + ciphertexts + tfhe-rs KS/MS/PBS reference outputs
//!   decrypt        decrypt PBS or KS outputs with tfhe-rs (shortint ClientKey) + noise stats
//!   verify-format  independent plain-integer re-computation of KS and MS (and layout checks)
//!   tfhe_noise     print tfhe-rs's public noise-formula predictions
//!
//! File formats and the exact maths are documented in docs/FORMATS.md.

mod fileio;
mod indep;

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::Instant;

use rayon::prelude::*;
use serde_json::{json, Value};

use tfhe::core_crypto::commons::generators::DeterministicSeeder;
use tfhe::core_crypto::commons::math::random::Seed;
use tfhe::core_crypto::commons::noise_formulas::centered_mean_shifted_modulus_switch::centered_binary_shifted_modulus_switch_additive_variance;
use tfhe::core_crypto::commons::noise_formulas::lwe_keyswitch::keyswitch_additive_variance_132_bits_security_tuniform;
use tfhe::core_crypto::commons::noise_formulas::lwe_programmable_bootstrap::pbs_variance_132_bits_security_tuniform_fft_mul;
use tfhe::core_crypto::commons::noise_formulas::modulus_switch::modulus_switch_additive_variance;
use tfhe::core_crypto::prelude::*;
use tfhe::shortint::atomic_pattern::{
    AtomicPatternKind, AtomicPatternServerKey, KS32AtomicPatternServerKey,
    StandardAtomicPatternServerKey,
};
use tfhe::shortint::ciphertext::{Degree, MaxDegree, NoiseLevel};
use tfhe::shortint::client_key::atomic_pattern::{
    AtomicPatternClientKey, KS32AtomicPatternClientKey, StandardAtomicPatternClientKey,
};
use tfhe::shortint::parameters::v1_8::{
    V1_8_PARAM_MESSAGE_2_CARRY_2_KS32_PBS_TUNIFORM_2M128,
    V1_8_PARAM_MESSAGE_2_CARRY_2_KS_PBS_TUNIFORM_2M128,
};
use tfhe::shortint::parameters::{CarryModulus, MessageModulus, PBSParameters};
use tfhe::shortint::server_key::{ModulusSwitchConfiguration, ShortintBootstrappingKey};
use tfhe::shortint::{Ciphertext, ClientKey, PBSOrder, ServerKey};

use fileio::*;

pub const TFHE_RS_VERSION: &str = "1.8.2";
const DELTA_LOG2: u32 = 59;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Variant {
    Ks32,
    Classic,
}

impl Variant {
    fn parse(s: &str) -> Variant {
        match s {
            "ks32" => Variant::Ks32,
            "classic" => Variant::Classic,
            _ => die(&format!("unknown variant {s} (ks32|classic)")),
        }
    }
    fn name(self) -> &'static str {
        match self {
            Variant::Ks32 => "ks32",
            Variant::Classic => "classic",
        }
    }
    fn param_name(self) -> &'static str {
        match self {
            Variant::Ks32 => "V1_8_PARAM_MESSAGE_2_CARRY_2_KS32_PBS_TUNIFORM_2M128",
            Variant::Classic => "V1_8_PARAM_MESSAGE_2_CARRY_2_KS_PBS_TUNIFORM_2M128",
        }
    }
    fn ks_bits(self) -> u32 {
        match self {
            Variant::Ks32 => 32,
            Variant::Classic => 64,
        }
    }
}

/// The handful of numbers both variants share in shape.
#[derive(Clone, Copy, Debug)]
struct P {
    n: usize,
    k: usize,
    big_n: usize,
    pbs_base_log: usize,
    pbs_level: usize,
    ks_base_log: usize,
    ks_level: usize,
    msg_mod: u64,
    carry_mod: u64,
    lwe_tuniform_log2: u32,
    glwe_tuniform_log2: u32,
    log2_p_fail: f64,
}

fn tuniform_log2<T: UnsignedInteger>(d: DynamicDistribution<T>) -> u32 {
    match d {
        DynamicDistribution::TUniform(t) => t.bound_log2(),
        DynamicDistribution::Gaussian(_) => die("expected a TUniform distribution"),
    }
}

fn params_of(v: Variant) -> P {
    match v {
        Variant::Ks32 => {
            let p = V1_8_PARAM_MESSAGE_2_CARRY_2_KS32_PBS_TUNIFORM_2M128;
            assert!(p.post_keyswitch_ciphertext_modulus.is_native_modulus());
            assert!(p.ciphertext_modulus.is_native_modulus());
            P {
                n: p.lwe_dimension.0,
                k: p.glwe_dimension.0,
                big_n: p.polynomial_size.0,
                pbs_base_log: p.pbs_base_log.0,
                pbs_level: p.pbs_level.0,
                ks_base_log: p.ks_base_log.0,
                ks_level: p.ks_level.0,
                msg_mod: p.message_modulus.0,
                carry_mod: p.carry_modulus.0,
                lwe_tuniform_log2: tuniform_log2(p.lwe_noise_distribution),
                glwe_tuniform_log2: tuniform_log2(p.glwe_noise_distribution),
                log2_p_fail: p.log2_p_fail,
            }
        }
        Variant::Classic => {
            let p = V1_8_PARAM_MESSAGE_2_CARRY_2_KS_PBS_TUNIFORM_2M128;
            assert!(p.ciphertext_modulus.is_native_modulus());
            assert!(matches!(
                p.encryption_key_choice,
                tfhe::shortint::EncryptionKeyChoice::Big
            ));
            P {
                n: p.lwe_dimension.0,
                k: p.glwe_dimension.0,
                big_n: p.polynomial_size.0,
                pbs_base_log: p.pbs_base_log.0,
                pbs_level: p.pbs_level.0,
                ks_base_log: p.ks_base_log.0,
                ks_level: p.ks_level.0,
                msg_mod: p.message_modulus.0,
                carry_mod: p.carry_modulus.0,
                lwe_tuniform_log2: tuniform_log2(p.lwe_noise_distribution),
                glwe_tuniform_log2: tuniform_log2(p.glwe_noise_distribution),
                log2_p_fail: p.log2_p_fail,
            }
        }
    }
}

fn die(msg: &str) -> ! {
    eprintln!("error: {msg}");
    std::process::exit(2)
}

// ------------------------------------------------------------------ LUTs

fn lut_fn(name: &str) -> fn(u64) -> u64 {
    match name {
        "sq3" => |x| (x * x + 3) % 16,
        "id" => |x| x,
        "mod4" => |x| x % 4,
        _ => die(&format!("unknown lut {name} (sq3|id|mod4)")),
    }
}

// ------------------------------------------------------------------ args

struct Args(BTreeMap<String, String>);

impl Args {
    fn parse(v: &[String]) -> Args {
        let mut m = BTreeMap::new();
        let mut i = 0;
        while i < v.len() {
            let key = v[i]
                .strip_prefix("--")
                .unwrap_or_else(|| die(&format!("unexpected argument {}", v[i])));
            if i + 1 >= v.len() {
                die(&format!("missing value for --{key}"));
            }
            m.insert(key.to_string(), v[i + 1].clone());
            i += 2;
        }
        Args(m)
    }
    fn get(&self, k: &str) -> Option<&str> {
        self.0.get(k).map(|s| s.as_str())
    }
    fn req(&self, k: &str) -> &str {
        self.get(k).unwrap_or_else(|| die(&format!("missing --{k}")))
    }
}

fn usage() -> ! {
    eprintln!(
        "tfhe_oracle (tfhe-rs {TFHE_RS_VERSION})\n\
         usage:\n  \
         tfhe_oracle gen --variant ks32|classic --seed S --count C [--lut sq3|id|mod4] --out DIR\n  \
         tfhe_oracle decrypt --keys DIR --input FILE --kind pbs|ks [--expect FILE.u8] [--json OUT]\n  \
         tfhe_oracle pbs --keys DIR --input FILE.u64 --lut NAME --out PREFIX\n  \
         tfhe_oracle scale --input FILE.u64 --w W --out FILE.u64\n  \
         tfhe_oracle expect --keys DIR [--lut NAME] [--w W] --out FILE.u8\n  \
         tfhe_oracle ms-stats --keys DIR --input FILE.ms.u32 [--expect FILE.u8] [--json OUT]\n  \
         tfhe_oracle verify-format --dir DIR [--exact-pbs K]\n  \
         tfhe_oracle tfhe_noise --variant ks32|classic"
    );
    std::process::exit(2)
}

fn main() {
    let argv: Vec<String> = std::env::args().collect();
    if argv.len() < 2 {
        usage();
    }
    let args = Args::parse(&argv[2..]);
    match argv[1].as_str() {
        "gen" => cmd_gen(&args),
        "decrypt" => cmd_decrypt(&args),
        "pbs" => cmd_pbs(&args),
        "scale" => cmd_scale(&args),
        "expect" => cmd_expect(&args),
        "ms-stats" => cmd_ms_stats(&args),
        "verify-format" => indep::cmd_verify_format(&args.0),
        "tfhe_noise" | "tfhe-noise" => cmd_noise(&args),
        _ => usage(),
    }
}

// ------------------------------------------------------------------ keys

/// All key material for one run, in tfhe-rs types.
struct Keys {
    lwe_sk_u64: Vec<u64>, // small key as 0/1 u64 (for files)
    lwe_sk32: Option<LweSecretKeyOwned<u32>>,
    lwe_sk64: Option<LweSecretKeyOwned<u64>>,
    glwe_sk: GlweSecretKeyOwned<u64>,
}

impl Keys {
    fn client_key(&self, v: Variant) -> ClientKey {
        let ap = match v {
            Variant::Ks32 => AtomicPatternClientKey::KeySwitch32(
                KS32AtomicPatternClientKey::from_raw_parts(
                    self.glwe_sk.clone(),
                    self.lwe_sk32.clone().unwrap(),
                    V1_8_PARAM_MESSAGE_2_CARRY_2_KS32_PBS_TUNIFORM_2M128,
                ),
            ),
            Variant::Classic => AtomicPatternClientKey::Standard(
                StandardAtomicPatternClientKey::from_raw_parts(
                    self.glwe_sk.clone(),
                    self.lwe_sk64.clone().unwrap(),
                    PBSParameters::PBS(V1_8_PARAM_MESSAGE_2_CARRY_2_KS_PBS_TUNIFORM_2M128),
                    None,
                ),
            ),
        };
        ClientKey { atomic_pattern: ap }
    }

    fn from_files(dir: &Path, v: Variant, p: &P) -> Keys {
        let lwe = read_u64(&dir.join("lwe_sk.u64"));
        let glwe = read_u64(&dir.join("glwe_sk.u64"));
        assert_eq!(lwe.len(), p.n);
        assert_eq!(glwe.len(), p.k * p.big_n);
        let glwe_sk = GlweSecretKeyOwned::from_container(glwe, PolynomialSize(p.big_n));
        match v {
            Variant::Ks32 => Keys {
                lwe_sk32: Some(LweSecretKeyOwned::from_container(
                    lwe.iter().map(|&x| x as u32).collect(),
                )),
                lwe_sk64: None,
                lwe_sk_u64: lwe,
                glwe_sk,
            },
            Variant::Classic => Keys {
                lwe_sk32: None,
                lwe_sk64: Some(LweSecretKeyOwned::from_container(lwe.clone())),
                lwe_sk_u64: lwe,
                glwe_sk,
            },
        }
    }
}

fn atomic_pattern_kind(v: Variant) -> AtomicPatternKind {
    match v {
        Variant::Ks32 => AtomicPatternKind::KeySwitch32,
        Variant::Classic => AtomicPatternKind::Standard(PBSOrder::KeyswitchBootstrap),
    }
}

fn wrap_ct(v: Variant, p: &P, ct: LweCiphertextOwned<u64>) -> Ciphertext {
    Ciphertext::new(
        ct,
        Degree::new(p.msg_mod * p.carry_mod - 1),
        NoiseLevel::NOMINAL,
        MessageModulus(p.msg_mod),
        CarryModulus(p.carry_mod),
        atomic_pattern_kind(v),
    )
}

/// splitmix64: message stream (not cryptographic, just reproducible).
struct SplitMix(u64);
impl SplitMix {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }
}

// ------------------------------------------------------------------ gen

fn cmd_gen(a: &Args) {
    let t_all = Instant::now();
    let v = Variant::parse(a.req("variant"));
    let seed: u64 = a.req("seed").parse().unwrap_or_else(|_| die("bad --seed"));
    let count: usize = a.req("count").parse().unwrap_or_else(|_| die("bad --count"));
    let lut_name = a.get("lut").unwrap_or("sq3").to_string();
    let f = lut_fn(&lut_name);
    let out = PathBuf::from(a.req("out"));
    std::fs::create_dir_all(&out).expect("create out dir");
    let p = params_of(v);
    let big_dim = p.k * p.big_n;
    let log_2n = CiphertextModulusLog((2 * p.big_n).ilog2() as usize);

    // ---- seeding: one DeterministicSeeder from S, distinct sub-seeds in a fixed order
    // (domain-separate the root seed by variant so ks32 and classic keys differ).
    let root: u128 = ((seed as u128) << 64) | (0x6F70_7573_0000_0000u128 + v.ks_bits() as u128);
    let mut seeder = DeterministicSeeder::<DefaultRandomGenerator>::new(Seed(root));
    let mut secret_gen = SecretRandomGenerator::<DefaultRandomGenerator>::new(seeder.seed());
    let mut bsk_gen =
        EncryptionRandomGenerator::<DefaultRandomGenerator>::new(seeder.seed(), &mut seeder);
    let mut ksk_gen =
        EncryptionRandomGenerator::<DefaultRandomGenerator>::new(seeder.seed(), &mut seeder);
    let mut enc_gen =
        EncryptionRandomGenerator::<DefaultRandomGenerator>::new(seeder.seed(), &mut seeder);
    let msg_seed = seeder.seed().0;
    let mut msg_rng = SplitMix((msg_seed as u64) ^ ((msg_seed >> 64) as u64));

    // ---- secret keys, same order as shortint ClientKey::new_with_engine (small LWE, then GLWE)
    let t = Instant::now();
    let (lwe_sk32, lwe_sk64): (Option<LweSecretKeyOwned<u32>>, Option<LweSecretKeyOwned<u64>>) =
        match v {
            Variant::Ks32 => (
                Some(allocate_and_generate_new_binary_lwe_secret_key(
                    LweDimension(p.n),
                    &mut secret_gen,
                )),
                None,
            ),
            Variant::Classic => (
                None,
                Some(allocate_and_generate_new_binary_lwe_secret_key(
                    LweDimension(p.n),
                    &mut secret_gen,
                )),
            ),
        };
    let glwe_sk: GlweSecretKeyOwned<u64> = allocate_and_generate_new_binary_glwe_secret_key(
        GlweDimension(p.k),
        PolynomialSize(p.big_n),
        &mut secret_gen,
    );
    let lwe_sk_u64: Vec<u64> = match v {
        Variant::Ks32 => lwe_sk32.as_ref().unwrap().as_ref().iter().map(|&x| x as u64).collect(),
        Variant::Classic => lwe_sk64.as_ref().unwrap().as_ref().to_vec(),
    };
    let keys = Keys { lwe_sk_u64, lwe_sk32, lwe_sk64, glwe_sk };
    let big_key = keys.glwe_sk.as_lwe_secret_key();

    // ---- standard-domain BSK (what ShortintEngine::new_classic_bootstrapping_key generates)
    let native = CiphertextModulus::<u64>::new_native();
    let (glwe_noise, bsk) = match v {
        Variant::Ks32 => {
            let pp = V1_8_PARAM_MESSAGE_2_CARRY_2_KS32_PBS_TUNIFORM_2M128;
            let bsk: LweBootstrapKeyOwned<u64> = par_allocate_and_generate_new_lwe_bootstrap_key(
                keys.lwe_sk32.as_ref().unwrap(),
                &keys.glwe_sk,
                pp.pbs_base_log,
                pp.pbs_level,
                pp.glwe_noise_distribution,
                pp.ciphertext_modulus,
                &mut bsk_gen,
            );
            (pp.glwe_noise_distribution, bsk)
        }
        Variant::Classic => {
            let pp = V1_8_PARAM_MESSAGE_2_CARRY_2_KS_PBS_TUNIFORM_2M128;
            let bsk: LweBootstrapKeyOwned<u64> = par_allocate_and_generate_new_lwe_bootstrap_key(
                keys.lwe_sk64.as_ref().unwrap(),
                &keys.glwe_sk,
                pp.pbs_base_log,
                pp.pbs_level,
                pp.glwe_noise_distribution,
                pp.ciphertext_modulus,
                &mut bsk_gen,
            );
            (pp.glwe_noise_distribution, bsk)
        }
    };
    let mut fbsk = FourierLweBootstrapKey::new(
        bsk.input_lwe_dimension(),
        bsk.glwe_size(),
        bsk.polynomial_size(),
        bsk.decomposition_base_log(),
        bsk.decomposition_level_count(),
    );
    par_convert_standard_lwe_bootstrap_key_to_fourier(&bsk, &mut fbsk);
    let t_bsk = t.elapsed();

    // ---- KSK big -> small (what the atomic-pattern ServerKey::new generates)
    let t = Instant::now();
    let ksk = match v {
        Variant::Ks32 => {
            let pp = V1_8_PARAM_MESSAGE_2_CARRY_2_KS32_PBS_TUNIFORM_2M128;
            Ksk::K32(allocate_and_generate_new_lwe_keyswitch_key(
                &big_key,
                keys.lwe_sk32.as_ref().unwrap(),
                pp.ks_base_log,
                pp.ks_level,
                pp.lwe_noise_distribution,
                pp.post_keyswitch_ciphertext_modulus,
                &mut ksk_gen,
            ))
        }
        Variant::Classic => {
            let pp = V1_8_PARAM_MESSAGE_2_CARRY_2_KS_PBS_TUNIFORM_2M128;
            Ksk::K64(allocate_and_generate_new_lwe_keyswitch_key(
                &big_key,
                keys.lwe_sk64.as_ref().unwrap(),
                pp.ks_base_log,
                pp.ks_level,
                pp.lwe_noise_distribution,
                pp.ciphertext_modulus,
                &mut ksk_gen,
            ))
        }
    };
    let t_ksk = t.elapsed();

    let sks = build_sks(v, &ksk, &fbsk);

    // ---- LUT with shortint semantics
    let lut = sks.generate_lookup_table(f);
    let table: Vec<u64> = (0..p.msg_mod * p.carry_mod).map(f).collect();
    assert_eq!(lut.acc.polynomial_size().0, p.big_n);
    assert_eq!(lut.acc.glwe_size().0, p.k + 1);
    assert!(lut.acc.get_mask().as_ref().iter().all(|&x| x == 0), "LUT mask not zero");
    let lut_body: Vec<u64> = lut.acc.get_body().as_ref().to_vec();

    // ---- messages + encryptions under the big key (shortint unchecked_encrypt semantics)
    let t = Instant::now();
    let modulus_total = p.msg_mod * p.carry_mod;
    let msgs: Vec<u8> = (0..count).map(|_| (msg_rng.next() % modulus_total) as u8).collect();
    let cts: Vec<LweCiphertextOwned<u64>> = msgs
        .iter()
        .map(|&m| {
            allocate_and_encrypt_new_lwe_ciphertext(
                &big_key,
                Plaintext((m as u64) << DELTA_LOG2),
                glwe_noise,
                native,
                &mut enc_gen,
            )
        })
        .collect();
    let t_enc = t.elapsed();

    // ---- tfhe-rs pipeline per ciphertext: KS -> centered MS -> BR -> SE
    let t = Instant::now();
    let rows = run_pipeline(v, &p, &sks, &fbsk, &ksk, &lut, &cts);
    let t_pbs = t.elapsed();

    // ---- blind-rotation probes: hand-made modulus-switched inputs with only the first M
    // mask entries non-zero, run through tfhe-rs's blind_rotate_assign + sample extract.
    // They let verify-format check the BR conventions against an exact integer BR while the
    // f64-FFT error has had few CMuxes to accumulate.
    let probe_m: Vec<usize> = vec![1, 1, 2, 4, 16, 64, 256, p.n];
    let mut probe_ms: Vec<u32> = Vec::new();
    let mut probe_pbs: Vec<u64> = Vec::new();
    let two_n = 2 * p.big_n as u64;
    for &mm in &probe_m {
        let mut v_ms = vec![0u32; p.n + 1];
        for x in v_ms.iter_mut().take(mm) {
            *x = (1 + msg_rng.next() % (two_n - 1)) as u32;
        }
        v_ms[p.n] = (msg_rng.next() % two_n) as u32;
        let lwe = LweCiphertextOwned::from_container(
            v_ms.iter().map(|&x| (x as u64) << (64 - log_2n.0)).collect::<Vec<u64>>(),
            native,
        );
        let lazy = LazyStandardModulusSwitchedLweCiphertext::<u64, usize, Vec<u64>>::from_raw_parts(
            lwe, 0u64, log_2n,
        );
        assert!(lazy.mask().zip(v_ms.iter()).all(|(a, &b)| a == b as usize));
        assert_eq!(lazy.body(), v_ms[p.n] as usize);
        let mut acc = lut.acc.clone();
        blind_rotate_assign(&lazy, &mut acc, &fbsk);
        let mut se = LweCiphertext::new(0u64, LweSize(big_dim + 1), native);
        extract_lwe_sample_from_glwe_ciphertext(&acc, &mut se, MonomialDegree(0));
        probe_ms.extend_from_slice(&v_ms);
        probe_pbs.extend_from_slice(se.as_ref());
    }

    // ---- write files
    let t = Instant::now();
    let mut files: Vec<Value> = Vec::new();
    let mut put = |name: &str, elem: &str, shape: Vec<usize>, bytes: Vec<u8>| {
        let sha = write_file(&out.join(name), &bytes);
        files.push(json!({"name": name, "elem": elem, "shape": shape,
                          "bytes": bytes.len(), "sha256": sha}));
    };
    put("lwe_sk.u64", "u64", vec![p.n], le_u64(&keys.lwe_sk_u64));
    put("glwe_sk.u64", "u64", vec![big_dim], le_u64(keys.glwe_sk.as_ref()));
    put(
        "bsk.u64",
        "u64",
        vec![p.n, p.pbs_level, p.k + 1, p.k + 1, p.big_n],
        le_u64(bsk.as_ref()),
    );
    match &ksk {
        Ksk::K32(k) => put("ksk.u32", "u32", vec![big_dim, p.ks_level, p.n + 1], le_u32(k.as_ref())),
        Ksk::K64(k) => put("ksk.u64", "u64", vec![big_dim, p.ks_level, p.n + 1], le_u64(k.as_ref())),
    }
    put("lut.u64", "u64", vec![p.big_n], le_u64(&lut_body));
    put("msg_in.u8", "u8", vec![count], msgs.clone());
    let lwe_in: Vec<u64> = cts.iter().flat_map(|c| c.as_ref().iter().copied()).collect();
    put("lwe_in.u64", "u64", vec![count, big_dim + 1], le_u64(&lwe_in));
    let ks_flat: Vec<u64> = rows.iter().flat_map(|r| r.ks.iter().copied()).collect();
    match v {
        Variant::Ks32 => put(
            "ref_ks_out.u32",
            "u32",
            vec![count, p.n + 1],
            le_u32(&ks_flat.iter().map(|&x| x as u32).collect::<Vec<_>>()),
        ),
        Variant::Classic => put("ref_ks_out.u64", "u64", vec![count, p.n + 1], le_u64(&ks_flat)),
    }
    let ms_flat: Vec<u32> = rows.iter().flat_map(|r| r.ms.iter().copied()).collect();
    put("ref_ms.u32", "u32", vec![count, p.n + 1], le_u32(&ms_flat));
    let pbs_flat: Vec<u64> = rows.iter().flat_map(|r| r.pbs.iter().copied()).collect();
    put("ref_pbs_out.u64", "u64", vec![count, big_dim + 1], le_u64(&pbs_flat));
    put("probe_ms.u32", "u32", vec![probe_m.len(), p.n + 1], le_u32(&probe_ms));
    put("probe_br_out.u64", "u64", vec![probe_m.len(), big_dim + 1], le_u64(&probe_pbs));
    let t_write = t.elapsed();

    let meta = json!({
        "tfhe_rs_version": TFHE_RS_VERSION,
        "param_set": v.param_name(),
        "variant": v.name(),
        "seed": seed,
        "count": count,
        "lut": {"name": lut_name, "table": table},
        "n": p.n, "k": p.k, "N": p.big_n,
        "pbs_base_log": p.pbs_base_log, "pbs_level": p.pbs_level,
        "ks_base_log": p.ks_base_log, "ks_level": p.ks_level,
        "message_modulus": p.msg_mod, "carry_modulus": p.carry_mod,
        "lwe_noise": {"kind": "TUniform", "bound_log2": p.lwe_tuniform_log2,
                       "modulus_log2": v.ks_bits()},
        "glwe_noise": {"kind": "TUniform", "bound_log2": p.glwe_tuniform_log2,
                        "modulus_log2": 64},
        "log2_p_fail": p.log2_p_fail,
        "ciphertext_modulus_log2": 64,
        "ks_output_modulus_log2": v.ks_bits(),
        "ms_output_modulus_log2": log_2n.0,
        "modulus_switch": "CenteredMeanNoiseReduction",
        "encryption_key_choice": "Big",
        "delta_log2": DELTA_LOG2,
        "padding_bit": true,
        "probe_nonzero_mask_counts": probe_m,
        "files": files,
        "timing_s": {"bsk_gen_and_fourier": t_bsk.as_secs_f64(), "ksk_gen": t_ksk.as_secs_f64(),
                      "encrypt": t_enc.as_secs_f64(), "ks_ms_pbs_all": t_pbs.as_secs_f64(),
                      "write": t_write.as_secs_f64(), "threads": rayon::current_num_threads()},
    });
    // timing is intentionally kept OUT of meta.json so meta.json is deterministic too
    let mut meta_det = meta.clone();
    meta_det.as_object_mut().unwrap().remove("timing_s");
    write_file(
        &out.join("meta.json"),
        serde_json::to_string_pretty(&meta_det).unwrap().as_bytes(),
    );
    println!("{}", serde_json::to_string_pretty(&meta["timing_s"]).unwrap());
    println!(
        "gen {} seed={} count={} lut={} -> {}  (total {:.2}s)",
        v.name(),
        seed,
        count,
        lut_name,
        out.display(),
        t_all.elapsed().as_secs_f64()
    );
}


pub enum Ksk {
    K32(LweKeyswitchKeyOwned<u32>),
    K64(LweKeyswitchKeyOwned<u64>),
}

pub struct Row {
    pub ks: Vec<u64>, // widened; written as u32 or u64
    pub ms: Vec<u32>,
    pub pbs: Vec<u64>,
}

/// shortint ServerKey from raw parts (Fourier BSK + KSK + centered-mean MS config)
fn build_sks(v: Variant, ksk: &Ksk, fbsk: &FourierLweBootstrapKeyOwned) -> ServerKey {
    let _ = v;
    let native = CiphertextModulus::<u64>::new_native();
    match ksk {
        Ksk::K32(k) => {
            let bk = ShortintBootstrappingKey::<u32>::Classic {
                bsk: fbsk.clone(),
                modulus_switch_noise_reduction_key:
                    ModulusSwitchConfiguration::CenteredMeanNoiseReduction,
            };
            let ap = KS32AtomicPatternServerKey::from_raw_parts(k.clone(), bk, native);
            let pp = V1_8_PARAM_MESSAGE_2_CARRY_2_KS32_PBS_TUNIFORM_2M128;
            ServerKey::from_raw_parts(
                AtomicPatternServerKey::KeySwitch32(ap),
                pp.message_modulus,
                pp.carry_modulus,
                MaxDegree::from_msg_carry_modulus(pp.message_modulus, pp.carry_modulus),
                pp.max_noise_level,
            )
        }
        Ksk::K64(k) => {
            let bk = ShortintBootstrappingKey::<u64>::Classic {
                bsk: fbsk.clone(),
                modulus_switch_noise_reduction_key:
                    ModulusSwitchConfiguration::CenteredMeanNoiseReduction,
            };
            let ap = StandardAtomicPatternServerKey::from_raw_parts(
                k.clone(),
                bk,
                PBSOrder::KeyswitchBootstrap,
            );
            let pp = V1_8_PARAM_MESSAGE_2_CARRY_2_KS_PBS_TUNIFORM_2M128;
            ServerKey::from_raw_parts(
                AtomicPatternServerKey::Standard(ap),
                pp.message_modulus,
                pp.carry_modulus,
                MaxDegree::from_msg_carry_modulus(pp.message_modulus, pp.carry_modulus),
                pp.max_noise_level,
            )
        }
    }
}

/// tfhe-rs pipeline per ciphertext: KS -> centered MS -> BR -> SE (parallel)
fn run_pipeline(
    v: Variant,
    p: &P,
    sks: &ServerKey,
    fbsk: &FourierLweBootstrapKeyOwned,
    ksk: &Ksk,
    lut: &tfhe::shortint::server_key::LookupTableOwned,
    cts: &[LweCiphertextOwned<u64>],
) -> Vec<Row> {
    let native = CiphertextModulus::<u64>::new_native();
    let big_dim = p.k * p.big_n;
    let log_2n = CiphertextModulusLog((2 * p.big_n).ilog2() as usize);
    let p = *p;
    cts
        .par_iter()
        .map(|ct| {
            // (a) KS + MS with the core_crypto calls the atomic pattern uses
            let (ks, ms): (Vec<u64>, Vec<u32>) = match ksk {
                Ksk::K32(k) => {
                    let mut o = LweCiphertext::new(
                        0u32,
                        LweSize(p.n + 1),
                        k.ciphertext_modulus(),
                    );
                    keyswitch_lwe_ciphertext_with_scalar_change(k, ct, &mut o);
                    let msed = lwe_ciphertext_centered_binary_modulus_switch::<u32, usize, _>(
                        o.as_view(),
                        log_2n,
                    );
                    let mut ms: Vec<u32> = msed.mask().map(|x| x as u32).collect();
                    ms.push(msed.body() as u32);
                    (o.as_ref().iter().map(|&x| x as u64).collect(), ms)
                }
                Ksk::K64(k) => {
                    let mut o = LweCiphertext::new(0u64, LweSize(p.n + 1), native);
                    keyswitch_lwe_ciphertext(k, ct, &mut o);
                    let msed = lwe_ciphertext_centered_binary_modulus_switch::<u64, usize, _>(
                        o.as_view(),
                        log_2n,
                    );
                    let mut ms: Vec<u32> = msed.mask().map(|x| x as u32).collect();
                    ms.push(msed.body() as u32);
                    (o.as_ref().to_vec(), ms)
                }
            };
            // (b) the full shortint PBS on the same input (it redoes KS/MS internally)
            let out = sks.apply_lookup_table(&wrap_ct(v, &p, ct.clone()), &lut);
            let pbs = out.ct.as_ref().to_vec();

            // (c) cross-check: core blind rotate + sample extract from OUR msed == shortint
            let mut acc = lut.acc.clone();
            match ksk {
                Ksk::K32(k) => {
                    let mut o = LweCiphertext::new(0u32, LweSize(p.n + 1), k.ciphertext_modulus());
                    keyswitch_lwe_ciphertext_with_scalar_change(k, ct, &mut o);
                    let msed = lwe_ciphertext_centered_binary_modulus_switch::<u32, usize, _>(
                        o.as_view(),
                        log_2n,
                    );
                    blind_rotate_assign(&msed, &mut acc, fbsk);
                }
                Ksk::K64(k) => {
                    let mut o = LweCiphertext::new(0u64, LweSize(p.n + 1), native);
                    keyswitch_lwe_ciphertext(k, ct, &mut o);
                    let msed = lwe_ciphertext_centered_binary_modulus_switch::<u64, usize, _>(
                        o.as_view(),
                        log_2n,
                    );
                    blind_rotate_assign(&msed, &mut acc, fbsk);
                }
            }
            let mut se = LweCiphertext::new(0u64, LweSize(big_dim + 1), native);
            extract_lwe_sample_from_glwe_ciphertext(&acc, &mut se, MonomialDegree(0));
            assert_eq!(
                se.as_ref(),
                pbs.as_slice(),
                "core-crypto chain disagrees with shortint apply_lookup_table"
            );
            Row { ks, ms, pbs }
        })
        .collect()
}

// ------------------------------------------------------------------ meta / decrypt

pub struct Meta {
    v: Variant,
    p: P,
    count: usize,
    table: Vec<u64>,
}

pub fn load_meta(dir: &Path) -> (Value, Meta) {
    let s = std::fs::read_to_string(dir.join("meta.json")).expect("read meta.json");
    let j: Value = serde_json::from_str(&s).expect("parse meta.json");
    let v = Variant::parse(j["variant"].as_str().unwrap());
    let p = params_of(v);
    assert_eq!(j["n"].as_u64().unwrap() as usize, p.n);
    assert_eq!(j["N"].as_u64().unwrap() as usize, p.big_n);
    let table = j["lut"]["table"].as_array().unwrap().iter().map(|x| x.as_u64().unwrap()).collect();
    let count = j["count"].as_u64().unwrap() as usize;
    (j, Meta { v, p, count, table })
}

#[derive(Default)]
struct Stats {
    errs: Vec<f64>,
    max_abs: u128,
}
impl Stats {
    fn push(&mut self, e: i128) {
        self.errs.push(e as f64);
        self.max_abs = self.max_abs.max(e.unsigned_abs());
    }
    fn summary(&self) -> (f64, f64) {
        let n = self.errs.len() as f64;
        let mean = self.errs.iter().sum::<f64>() / n;
        let var = self.errs.iter().map(|e| (e - mean) * (e - mean)).sum::<f64>() / (n - 1.0).max(1.0);
        (mean, var.sqrt())
    }
}

fn cmd_decrypt(a: &Args) {
    let dir = PathBuf::from(a.req("keys"));
    let input = PathBuf::from(a.req("input"));
    let kind = a.req("kind");
    let (_j, m) = load_meta(&dir);
    let p = m.p;
    let v = m.v;
    let keys = Keys::from_files(&dir, v, &p);
    let msgs = read_u8(&dir.join("msg_in.u8"));
    let expect_file: Option<Vec<u8>> = a.get("expect").map(|f| read_u8(Path::new(f)));
    let big_dim = p.k * p.big_n;
    let mut fails: Vec<Value> = Vec::new();
    let mut st = Stats::default();
    let (unit_log2, delta_log2): (u32, u32);
    match kind {
        "pbs" => {
            let cks = keys.client_key(v);
            let data = read_u64(&input);
            assert_eq!(data.len() % (big_dim + 1), 0);
            let c = data.len() / (big_dim + 1);
            assert!(c <= expect_file.as_ref().map_or(msgs.len(), |e| e.len()), "more ciphertexts than expected values");
            unit_log2 = 64;
            delta_log2 = DELTA_LOG2;
            for i in 0..c {
                let ct = LweCiphertextOwned::from_container(
                    data[i * (big_dim + 1)..(i + 1) * (big_dim + 1)].to_vec(),
                    CiphertextModulus::new_native(),
                );
                let sct = wrap_ct(v, &p, ct);
                // shortint ClientKey decryption: round(phase / Delta) mod (2 * msg * carry)
                let dec = cks.decrypt_message_and_carry(&sct);
                let expect = match &expect_file {
                    Some(e) => e[i] as u64,
                    None => m.table[msgs[i] as usize],
                };
                let phase = cks.decrypt_no_decode(&sct).0;
                let e = phase.wrapping_sub(expect << DELTA_LOG2) as i64;
                st.push(e as i128);
                if dec != expect {
                    fails.push(json!({"index": i, "expected": expect, "got": dec,
                                       "err": e}));
                }
            }
        }
        "ks" => {
            let ks_bits = v.ks_bits();
            unit_log2 = ks_bits;
            delta_log2 = DELTA_LOG2 - (64 - ks_bits);
            let s = &keys.lwe_sk_u64;
            let rows: Vec<Vec<u64>> = if ks_bits == 32 {
                read_u32(&input).iter().map(|&x| x as u64).collect::<Vec<_>>()
            } else {
                read_u64(&input)
            }
            .chunks(p.n + 1)
            .map(|c| c.to_vec())
            .collect();
            let mask: u64 = if ks_bits == 64 { u64::MAX } else { (1u64 << ks_bits) - 1 };
            let half_space = 2 * p.msg_mod * p.carry_mod; // with padding bit
            for (i, r) in rows.iter().enumerate() {
                // tfhe-rs decrypt_lwe_ciphertext under the small key, then shortint decode
                let ct_mod = if ks_bits == 32 {
                    let ct = LweCiphertextOwned::from_container(
                        r.iter().map(|&x| x as u32).collect::<Vec<u32>>(),
                        CiphertextModulus::<u32>::new_native(),
                    );
                    decrypt_lwe_ciphertext(keys.lwe_sk32.as_ref().unwrap(), &ct).0 as u64
                } else {
                    let ct = LweCiphertextOwned::from_container(r.clone(), CiphertextModulus::new_native());
                    decrypt_lwe_ciphertext(keys.lwe_sk64.as_ref().unwrap(), &ct).0
                };
                // independent check of the phase
                let mut ph = r[p.n];
                for j in 0..p.n {
                    ph = ph.wrapping_sub(r[j].wrapping_mul(s[j]));
                }
                assert_eq!(ph & mask, ct_mod & mask);
                let expect = match &expect_file {
                    Some(e) => e[i] as u64,
                    None => msgs[i] as u64,
                };
                let e_u = ct_mod.wrapping_sub(expect << delta_log2) & mask;
                let e: i128 = if ks_bits == 32 { (e_u as u32 as i32) as i128 } else { (e_u as i64) as i128 };
                // decode: round(phase / Delta) mod 2*p
                let dec = ((ct_mod as u128 + (1u128 << (delta_log2 - 1))) >> delta_log2) as u64 % half_space;
                st.push(e);
                if dec != expect {
                    fails.push(json!({"index": i, "expected": expect, "got": dec, "err": e as i64}));
                }
            }
        }
        _ => die("--kind must be pbs or ks"),
    }
    let (mean, std) = st.summary();
    let half_delta = 2f64.powi(delta_log2 as i32 - 1);
    let res = json!({
        "kind": kind,
        "variant": v.name(),
        "input": input.display().to_string(),
        "count": st.errs.len(),
        "failures": fails.len(),
        "failure_list": fails,
        "error_unit": format!("2^{unit_log2} modulus units"),
        "mean": mean,
        "std": std,
        "log2_std": std.log2(),
        "max_abs": st.max_abs as f64,
        "log2_max_abs": (st.max_abs as f64).log2(),
        "decision_bound": half_delta,
        "margin_sigma": half_delta / std,
    });
    println!("{}", serde_json::to_string_pretty(&res).unwrap());
    if let Some(o) = a.get("json") {
        std::fs::write(o, serde_json::to_string_pretty(&res).unwrap()).unwrap();
    }
    if !fails.is_empty() {
        std::process::exit(1);
    }
}

// ------------------------------------------------------------------ noise formulas

fn cmd_noise(a: &Args) {
    let v = Variant::parse(a.req("variant"));
    let p = params_of(v);
    let q64 = 2f64.powi(64);
    let qks = 2f64.powi(v.ks_bits() as i32);
    let two_n = (2 * p.big_n) as f64;
    // tfhe-rs variances are normalised to the torus (value / modulus)^2
    let fresh = TUniform::<u64>::new(p.glwe_tuniform_log2).variance(q64).0;
    let ks_add = keyswitch_additive_variance_132_bits_security_tuniform(
        LweDimension(p.k * p.big_n),
        LweDimension(p.n),
        DecompositionBaseLog(p.ks_base_log),
        DecompositionLevelCount(p.ks_level),
        q64,
        qks,
    )
    .0;
    let ms_centered =
        centered_binary_shifted_modulus_switch_additive_variance(LweDimension(p.n), qks, two_n).0;
    let ms_plain = modulus_switch_additive_variance(LweDimension(p.n), qks, two_n).0;
    let pbs = pbs_variance_132_bits_security_tuniform_fft_mul(
        LweDimension(p.n),
        GlweDimension(p.k),
        PolynomialSize(p.big_n),
        DecompositionBaseLog(p.pbs_base_log),
        DecompositionLevelCount(p.pbs_level),
        53.0,
        q64,
    )
    .0;
    let to64 = |var: f64| var.sqrt() * q64;
    let bound = 2f64.powi(DELTA_LOG2 as i32 - 1) / q64; // half a Delta, torus units
    let pre_br = fresh + ks_add + ms_centered;
    let res = json!({
        "variant": v.name(),
        "note": "tfhe-rs public formulas in core_crypto::commons::noise_formulas (1.8.2); variances normalised to the torus; std_2^64 = sqrt(var)*2^64",
        "fresh_encryption_var": fresh, "fresh_std_2^64": to64(fresh),
        "ks_additive_var": ks_add, "ks_additive_std_2^64": to64(ks_add),
        "ks_out_total_var": fresh + ks_add, "ks_out_total_std_2^64": to64(fresh+ks_add),
        "ms_centered_additive_var": ms_centered, "ms_centered_std_2^64": to64(ms_centered),
        "ms_plain_additive_var(for comparison)": ms_plain,
        "pre_blind_rotate_total_var": pre_br, "pre_br_std_2^64": to64(pre_br),
        "pre_br_margin_sigma": bound / pre_br.sqrt(),
        "pbs_out_var(fft, mantissa 53)": pbs, "pbs_out_std_2^64": to64(pbs),
        "pbs_out_log2_std_2^64": to64(pbs).log2(),
        "pbs_out_margin_sigma": bound / pbs.sqrt(),
    });
    println!("{}", serde_json::to_string_pretty(&res).unwrap());
}

// ------------------------------------------------------------------ chain tools

/// Load the server-side material written by `gen` and rebuild the tfhe-rs objects.
fn load_server(dir: &Path, v: Variant, p: &P) -> (Ksk, FourierLweBootstrapKeyOwned) {
    let native = CiphertextModulus::<u64>::new_native();
    let bsk = LweBootstrapKeyOwned::from_container(
        read_u64(&dir.join("bsk.u64")),
        GlweSize(p.k + 1),
        PolynomialSize(p.big_n),
        DecompositionBaseLog(p.pbs_base_log),
        DecompositionLevelCount(p.pbs_level),
        native,
    );
    assert_eq!(bsk.input_lwe_dimension().0, p.n);
    let mut fbsk = FourierLweBootstrapKey::new(
        bsk.input_lwe_dimension(),
        bsk.glwe_size(),
        bsk.polynomial_size(),
        bsk.decomposition_base_log(),
        bsk.decomposition_level_count(),
    );
    par_convert_standard_lwe_bootstrap_key_to_fourier(&bsk, &mut fbsk);
    let ksk = match v {
        Variant::Ks32 => Ksk::K32(LweKeyswitchKeyOwned::from_container(
            read_u32(&dir.join("ksk.u32")),
            DecompositionBaseLog(p.ks_base_log),
            DecompositionLevelCount(p.ks_level),
            LweSize(p.n + 1),
            CiphertextModulus::<u32>::new_native(),
        )),
        Variant::Classic => Ksk::K64(LweKeyswitchKeyOwned::from_container(
            read_u64(&dir.join("ksk.u64")),
            DecompositionBaseLog(p.ks_base_log),
            DecompositionLevelCount(p.ks_level),
            LweSize(p.n + 1),
            native,
        )),
    };
    (ksk, fbsk)
}

fn cmd_pbs(a: &Args) {
    let t0 = Instant::now();
    let dir = PathBuf::from(a.req("keys"));
    let (_j, m) = load_meta(&dir);
    let (v, p) = (m.v, m.p);
    let lut_name = a.req("lut");
    let f = lut_fn(lut_name);
    let prefix = a.req("out").to_string();
    let big_dim = p.k * p.big_n;
    let (ksk, fbsk) = load_server(&dir, v, &p);
    let sks = build_sks(v, &ksk, &fbsk);
    let lut = sks.generate_lookup_table(f);
    let data = read_u64(Path::new(a.req("input")));
    assert_eq!(data.len() % (big_dim + 1), 0);
    let cts: Vec<LweCiphertextOwned<u64>> = data
        .chunks(big_dim + 1)
        .map(|c| LweCiphertextOwned::from_container(c.to_vec(), CiphertextModulus::new_native()))
        .collect();
    let t = Instant::now();
    let rows = run_pipeline(v, &p, &sks, &fbsk, &ksk, &lut, &cts);
    let t_pbs = t.elapsed();
    let ks_flat: Vec<u64> = rows.iter().flat_map(|r| r.ks.iter().copied()).collect();
    let mut shas = Vec::new();
    match v {
        Variant::Ks32 => shas.push(("ks.u32", write_file(Path::new(&format!("{prefix}.ks.u32")),
            &le_u32(&ks_flat.iter().map(|&x| x as u32).collect::<Vec<_>>())))),
        Variant::Classic => shas.push(("ks.u64", write_file(Path::new(&format!("{prefix}.ks.u64")), &le_u64(&ks_flat)))),
    }
    let ms_flat: Vec<u32> = rows.iter().flat_map(|r| r.ms.iter().copied()).collect();
    shas.push(("ms.u32", write_file(Path::new(&format!("{prefix}.ms.u32")), &le_u32(&ms_flat))));
    let pbs_flat: Vec<u64> = rows.iter().flat_map(|r| r.pbs.iter().copied()).collect();
    shas.push(("pbs.u64", write_file(Path::new(&format!("{prefix}.pbs.u64")), &le_u64(&pbs_flat))));
    for (n, s) in &shas {
        println!("  {prefix}.{n}  sha256 {s}");
    }
    println!(
        "pbs {} lut={} count={} -> {prefix}.*  (pipeline {:.2}s, total {:.2}s)",
        v.name(), lut_name, cts.len(), t_pbs.as_secs_f64(), t0.elapsed().as_secs_f64()
    );
}

fn cmd_scale(a: &Args) {
    let w: u64 = a.req("w").parse().unwrap_or_else(|_| die("bad --w"));
    let data = read_u64(Path::new(a.req("input")));
    let out: Vec<u64> = data.iter().map(|x| x.wrapping_mul(w)).collect();
    let sha = write_file(Path::new(a.req("out")), &le_u64(&out));
    println!("scale x{w}: {} words -> {} sha256 {sha}", data.len(), a.req("out"));
}

/// expected cleartexts: (W * f(msg_in)) for the f in --lut (default: meta's LUT)
fn cmd_expect(a: &Args) {
    let dir = PathBuf::from(a.req("keys"));
    let (_j, m) = load_meta(&dir);
    let w: u64 = a.get("w").unwrap_or("1").parse().unwrap();
    let msgs = read_u8(&dir.join("msg_in.u8"));
    let out: Vec<u8> = msgs
        .iter()
        .map(|&x| {
            let fx = match a.get("lut") {
                Some(n) => lut_fn(n)(x as u64),
                None => m.table[x as usize],
            };
            let e = w * fx;
            assert!(e < 2 * m.p.msg_mod * m.p.carry_mod, "expected value overflows the padding bit");
            e as u8
        })
        .collect();
    let sha = write_file(Path::new(a.req("out")), &out);
    println!("expect: {} values -> {} sha256 {sha}", out.len(), a.req("out"));
}

/// erfc with fractional error < 1.2e-7 everywhere (Chebyshev fit, Numerical Recipes "erfcc").
fn erfc(x: f64) -> f64 {
    let z = x.abs();
    let t = 1.0 / (1.0 + 0.5 * z);
    let ans = t * (-z * z - 1.26551223
        + t * (1.00002368
            + t * (0.37409196
                + t * (0.09678418
                    + t * (-0.18628806
                        + t * (0.27886807
                            + t * (-1.13520398
                                + t * (1.48851587 + t * (-0.82215223 + t * 0.17087277)))))))))
        .exp();
    if x >= 0.0 { ans } else { 2.0 - ans }
}

/// P[X < lo] + P[X >= hi] for X ~ N(mean, std^2), as log2.
fn log2_gauss_out(mean: f64, std: f64, lo: f64, hi: f64) -> f64 {
    let s2 = std * std::f64::consts::SQRT_2;
    let p = 0.5 * erfc((hi - mean) / s2) + 0.5 * erfc((mean - lo) / s2);
    p.log2()
}

/// Error statistics in the modulus-switched domain (units of 1/(2N) of the torus).
fn cmd_ms_stats(a: &Args) {
    let dir = PathBuf::from(a.req("keys"));
    let (_j, m) = load_meta(&dir);
    let p = m.p;
    let two_n = 2 * p.big_n as i64;
    let s = read_u64(&dir.join("lwe_sk.u64"));
    let ms = read_u32(Path::new(a.req("input")));
    assert_eq!(ms.len() % (p.n + 1), 0);
    let c = ms.len() / (p.n + 1);
    let expect: Vec<u64> = match a.get("expect") {
        Some(f) => read_u8(Path::new(f)).iter().map(|&x| x as u64).collect(),
        None => read_u8(&dir.join("msg_in.u8")).iter().map(|&x| x as u64).collect(),
    };
    let step = two_n / (2 * (p.msg_mod * p.carry_mod) as i64); // 2N / 32 = 128
    let mut errs: Vec<f64> = Vec::with_capacity(c);
    let mut fails = Vec::new();
    let (mut emin, mut emax) = (i64::MAX, i64::MIN);
    for i in 0..c {
        let r = &ms[i * (p.n + 1)..(i + 1) * (p.n + 1)];
        let mut ph: i64 = r[p.n] as i64;
        for j in 0..p.n {
            ph -= (r[j] as i64) * (s[j] as i64);
        }
        let ideal = step * expect[i] as i64;
        // centred representative of (phase - ideal) mod 2N, in [-N, N)
        let e = (ph - ideal).rem_euclid(two_n);
        let e = if e >= two_n / 2 { e - two_n } else { e };
        if e < -step / 2 || e >= step / 2 {
            fails.push(json!({"index": i, "expected": expect[i], "err": e}));
        }
        emin = emin.min(e);
        emax = emax.max(e);
        errs.push(e as f64);
    }
    let n = c as f64;
    let mean = errs.iter().sum::<f64>() / n;
    let std = (errs.iter().map(|e| (e - mean) * (e - mean)).sum::<f64>() / (n - 1.0)).sqrt();
    let h = (step / 2) as f64;
    let res = json!({
        "input": a.req("input"),
        "count": c,
        "unit": "1/(2N) of the torus (2N = 4096); correct iff err in [-64, 64)",
        "mean": mean, "std": std, "min": emin, "max": emax,
        "failures": fails.len(), "failure_list": fails,
        "log2_pfail_gauss_[-64,64)": log2_gauss_out(mean, std, -h, h),
        "log2_pfail_gauss_continuity_[-64.5,63.5)": log2_gauss_out(mean, std, -h - 0.5, h - 0.5),
        "margin_sigma_lo": (mean + h) / std,
        "margin_sigma_hi": (h - mean) / std,
    });
    println!("{}", serde_json::to_string_pretty(&res).unwrap());
    if let Some(o) = a.get("json") {
        std::fs::write(o, serde_json::to_string_pretty(&res).unwrap()).unwrap();
    }
}
