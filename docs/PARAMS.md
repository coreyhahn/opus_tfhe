# PARAMS — the locked parameter set

**Locked 2026-10-19 (Stage 0).** tfhe-rs **1.8.2** (crates.io `tfhe = "=1.8.2"`, feature
`shortint`, released 2026-10-19; source read from the cargo registry copy
`~/.cargo/registry/src/index.crates.io-*/tfhe-1.8.2/`). All paths below are relative to that
crate's `src/`.

## The set: `PARAM_MESSAGE_2_CARRY_2_KS32_PBS_TUNIFORM_2M128`

The alias `shortint::parameters::PARAM_MESSAGE_2_CARRY_2_KS32_PBS_TUNIFORM_2M128`
(`shortint/parameters/aliases.rs:64-65`) resolves to
`V1_8_PARAM_MESSAGE_2_CARRY_2_KS32_PBS_TUNIFORM_2M128`, a `KeySwitch32PBSParameters` defined at
`shortint/parameters/v1_8/ks32/tuniform/p_fail_2_minus_128/ks_pbs.rs:8-26`.

| Field | Value | Meaning | Source line (ks_pbs.rs above unless noted) |
|---|---|---|---|
| `lwe_dimension` n | **918** | small LWE key length = CMuxes per PBS | :10 |
| `glwe_dimension` k | **1** | GLWE mask polynomials | :11 |
| `polynomial_size` N | **2048** | ring Z_q[X]/(X^N+1) | :12 |
| `lwe_noise_distribution` | **TUniform(13)** on the u32 post-KS torus (= 2^45 at 64-bit scale) | KSK noise | :13 |
| `glwe_noise_distribution` | **TUniform(17)** on the u64 torus | BSK noise and fresh big-key encryptions | :14 |
| `pbs_base_log` β | **23** | gadget base 2^23 | :15 |
| `pbs_level` ℓ | **1** | one digit per coefficient | :16 |
| `ks_base_log` | **4** | KS gadget base 2^4 | :17 |
| `ks_level` | **4** | KS digits (top 16 bits of each u64 mask element) | :18 |
| `message_modulus` | **4** | 2-bit message | :19 |
| `carry_modulus` | **4** | 2-bit carry → 16-value plaintext space + padding bit | :20 |
| `max_noise_level` | **5** | KS input may be a combination of PBS outputs of 2-norm ≤ 5 | :21 |
| `log2_p_fail` | **−129.581** | per-PBS failure probability **2^-129.58** at max_noise_level | :22 |
| `post_keyswitch_ciphertext_modulus` | **2^32 native** (`CiphertextModulus32::new_native()`) | KS output / KSK word modulus | :23 |
| `ciphertext_modulus` | **2^64 native** | inputs, BSK, accumulator, PBS output | :24 |
| `modulus_switch_noise_reduction_params` | **`ModulusSwitchType::CenteredMeanNoiseReduction`** | centred-mean modulus switch to 2N before blind rotation | :25 |
| encryption key choice | **Big** (KS then PBS) | fixed for KS32 (`shortint/parameters/ks32.rs:117-120`) | ks32.rs:117 |

TUniform(b) definition (`core_crypto/commons/math/random/t_uniform.rs:8-10`): every integer in
[−2^b, 2^b] with probability 2^-(b+1), the end points with probability 2^-(b+2); variance
(2^(2b+1)+1)/6 ≈ 2^(2b)/3.

### Derived constants [derived]

| Quantity | Value |
|---|---|
| Plaintext space, encoding | 16 values (message ⊕ carry) + 1 padding bit; Δ = 2^63/16 = **2^59** |
| Big (GLWE) LWE dimension k·N | 2048; LWE ciphertext = 2049 u64 = 16,392 B |
| Modulus-switch target | 2N = 4096 (log2 = 12); one message box = 128 units, half box 64 |
| BSK, tfhe-rs standard domain | n·(k+1)·ℓ·(k+1)·N·8 B = **60,162,048 B** (57.4 MiB) |
| KSK (u32 words) | k·N·ℓ_ks·(n+1)·4 B = **30,113,792 B** (28.7 MiB) |

## Why this set (and not the classic 64-bit-KS sibling)

`PARAM_MESSAGE_2_CARRY_2_KS_PBS_TUNIFORM_2M128` (aliases.rs:54-55 → `V1_4_...` at
`shortint/parameters/v1_4/classic/tuniform/p_fail_2_minus_128/ks_pbs.rs:29-47`) is identical in
every PBS field (n=918, k=1, N=2048, 23×1, TUniform(17), centred-mean MS, p-fail 2^-129.581) and
differs only in the key switch: 64-bit KSK words with TUniform(45) on the u64 torus, i.e. the same
noise at the same scale. The KS32 set halves the KSK to 30.1 MB, which fits in the VU9P's URAM
(35.4 MB) so that the key switch never touches DDR4; the classic KSK (60.2 MB) would have to stream
beside the BSK, which does not fit the device's memory budget. **Every figure this project publishes names
`PARAM_MESSAGE_2_CARRY_2_KS32_PBS_TUNIFORM_2M128`, p-fail 2^-129.58.** The reference model and the
oracle support the classic sibling too (`--variant classic`), and Stage 0 validates both.

Comparison sets used by the published rows (never ours; quote them with their names):

| Row | Set | Differences from ours |
|---|---|---|
| Zama HPU (V80) | `HPU_PARAM_MESSAGE_2_CARRY_2_KS32_PBS_TUNIFORM_2M128` (`shortint/parameters/v1_8/hpu.rs:11-29`) | n=879, KS base 2 / level 8, post-KS modulus 2^21, LWE noise TUniform(3), p-fail 2^-128.0 |
| tfhe-rs GPU multi-bit | `PARAM_GPU_MULTI_BIT_GROUP_4_MESSAGE_2_CARRY_2_KS_PBS_TUNIFORM_2M128` | multi-bit PBS, grouping 4 |
| VCU128 (arXiv 2510.23483) | n=500, N=1024, k=1, ℓ=2, β=10, Goldilocks ciphertext modulus, DFR 2^-64 claimed | no KS in the measured figure |

## Engine arithmetic parameters (ours, not tfhe-rs's)

These do not change the parameter set; they define how the engine evaluates it. The reference model `ref/tfhe_model` implements exactly
this and Stage 0 validates it by tfhe-rs decryption.

| Quantity | Value |
|---|---|
| Blind-rotation ring | Z_Q[X]/(X^2048+1), Q = p1·p2·p3 |
| RNS primes (≡ 1 mod 4096, < 2^18, sparse) | p1 = 249857 = 2^18−2^14+2^12+1, p2 = 188417 = 2^18−2^16−2^13+1, p3 = 163841 = 2^17+2^15+1 |
| log2 Q | 52.79 |
| BSK, LUT into Z_Q | φ(t) = round(t·Q / 2^64) (host side, once per key) |
| Digit (ℓ=1) | d = round(x·2^23/Q) mod 2^23, centred in [−2^22, 2^22), by approximate CRT with F = 28 fractional bits (F = 32 in the Stage 0 evidence run) |
| Output back to the torus | ψ(x) = round(x·2^64/Q) mod 2^64 by approximate CRT, F = 28 |
| Key switch, modulus switch | bit-identical to tfhe-rs (verified, evidence/stage0/) |
