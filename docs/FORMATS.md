# FORMATS: oracle files and the exact integer maths of tfhe-rs 1.8.2's KS-PBS

This document describes two things:

1. The flat files that `ref/tfhe_oracle` writes.
2. The exact integer rules that an independent implementation must follow to match
   tfhe-rs **1.8.2** (`tfhe = "=1.8.2"`) bit for bit, for the parameter sets
   `V1_8_PARAM_MESSAGE_2_CARRY_2_KS32_PBS_TUNIFORM_2M128` (variant `ks32`, the primary)
   and `V1_8_PARAM_MESSAGE_2_CARRY_2_KS_PBS_TUNIFORM_2M128` (variant `classic`).

The notation and wording here are our own. Citations have the form `path:line`. Paths are
relative to `~/.cargo/registry/src/index.crates.io-*/tfhe-1.8.2/src/`. Every rule in
sections 3 and 4 has been checked by the plain-integer code in
`ref/tfhe_oracle/src/indep.rs` (`tfhe_oracle verify-format`). That check matches
`ref_ks_out` and `ref_ms` bit for bit on 1000/1000 ciphertexts for both variants
(`evidence/stage0/oracle_{ks32,classic}.log`). Sections 5 and 6 are checked by decrypting
GGSW rows and by an exact blind rotation (see section 7 for why "bit-exact" is not
achievable there).

## 0. Notation

| symbol | ks32 | classic | meaning |
|---|---|---|---|
| n | 918 | 918 | small LWE dimension |
| k | 1 | 1 | GLWE dimension |
| N | 2048 | 2048 | polynomial size |
| kN | 2048 | 2048 | big LWE dimension (input and output of the PBS) |
| q | 2^64 | 2^64 | ciphertext modulus of the input, the BSK and the PBS output |
| w | 32 | 64 | bit width of the KS output and the KSK (`post_keyswitch_ciphertext_modulus` = native 2^32 for ks32) |
| β_pbs, l_pbs | 23, 1 | 23, 1 | PBS decomposition base log and level count |
| β_ks, l_ks | 4, 4 | 4, 4 | KS decomposition base log and level count |
| p | 16 | 16 | message_modulus × carry_modulus = 4 × 4 |
| Δ | 2^59 | 2^59 | encoding scale = 2^63 / p (one padding bit) |
| lwe noise | TUniform(13) mod 2^32 | TUniform(45) mod 2^64 | KSK noise |
| glwe noise | TUniform(17) mod 2^64 | TUniform(17) mod 2^64 | BSK noise, and fresh-encryption noise (Big key) |
| log2 p_fail | -129.581 | -129.581 | |

Sources: `shortint/parameters/v1_8/ks32/tuniform/p_fail_2_minus_128/ks_pbs.rs:8-26`. The classic
v1.8 constant is an alias (`shortint/parameters/v1_8/classic/tuniform/p_fail_2_minus_128/ks_pbs.rs:6`)
of `shortint/parameters/v1_4/classic/tuniform/p_fail_2_minus_128/ks_pbs.rs:29-47`.
The two sets are the same apart from the KS output width and the KS noise: ks32 uses
TUniform(13) on 2^32, which is 2^45 on the 2^64 scale, so the noise is identical on the torus.

TUniform(b) draws an integer uniformly from [-2^b, 2^b]. The two end values have half the
probability of the others. The variance is (2^(2b+1)+1)/6 in integer units
(`core_crypto/commons/math/random/t_uniform.rs:75`).

All arithmetic is in unsigned integers modulo 2^w, with wrap-around, unless a signed
interpretation is stated. "signed(x)" means the two's-complement value of x in w bits.
A ⋅ B for polynomials means the product mod (X^N + 1), with coefficients mod 2^64.
A pair of polynomials or vectors is written (mask…, body).

## 1. Files written by `tfhe_oracle gen`

Every file is little-endian and has no header. Arrays are row-major in the shape listed, with
the last index fastest. `meta.json` lists each file with its element type, shape, byte count
and sha256.

| file | element | shape | content |
|---|---|---|---|
| `meta.json` | text | | tfhe-rs version, parameter-set name, variant, seed, count, LUT name and 16-entry table, n, k, N, base logs and levels, moduli, noise bound_log2, log2_p_fail, `ks_output_modulus_log2`, `delta_log2`, the probe mask counts, and the file list with sha256 |
| `lwe_sk.u64` | u64 | [n] | small LWE secret key, 0/1 |
| `glwe_sk.u64` | u64 | [k·N] | GLWE secret key, 0/1, as polynomials S_0..S_{k-1}, coefficient 0 first. **This is also the big LWE key, in the same order**: s_big[r·N + c] = S_r[c] (`core_crypto/entities/glwe_secret_key.rs:123`) |
| `bsk.u64` | u64 | [n][l_pbs][k+1][k+1][N] | standard-domain (coefficient-domain) bootstrap key: GGSW i, stored level t, row r, polynomial c, coefficient. See section 5 |
| `ksk.u32` (ks32) / `ksk.u64` (classic) | u32/u64 | [kN][l_ks][n+1] | keyswitch key big→small: input index i, stored level t, LWE (n mask values, then body). See section 3 |
| `lut.u64` | u64 | [N] | accumulator **body** polynomial. Its mask is all zero (asserted). See section 6 |
| `msg_in.u8` | u8 | [C] | cleartexts m, uniform in [0,16) |
| `lwe_in.u64` | u64 | [C][kN+1] | Enc_big(m): kN mask values, then body |
| `ref_ks_out.u32` / `.u64` | u32/u64 | [C][n+1] | tfhe-rs keyswitch output |
| `ref_ms.u32` | u32 | [C][n+1] | modulus-switched LWE: n mask values ã_i then body b̃, each in [0, 2N) |
| `ref_pbs_out.u64` | u64 | [C][kN+1] | tfhe-rs PBS output (KS → MS → BR → SE) |
| `probe_ms.u32` | u32 | [8][n+1] | hand-made modulus-switched inputs. Only the first M mask entries are non-zero, with M = 1,1,2,4,16,64,256,918 |
| `probe_br_out.u64` | u64 | [8][kN+1] | tfhe-rs blind rotation + sample extraction of the probes (no KS/MS) |

`tfhe_oracle pbs --keys DIR --input F --lut NAME --out PREFIX` writes `PREFIX.ks.u32|u64`,
`PREFIX.ms.u32` and `PREFIX.pbs.u64` in the same layouts as `ref_*`.

Sizes for ks32 with C=1000: bsk 60,162,048 B; ksk 30,113,792 B; lwe_in and ref_pbs_out
16,392,000 B each; ref_ks_out and ref_ms 3,676,000 B each. The classic ksk is twice as large
(u64).

### Seeding (oracle-specific, not a tfhe-rs rule)

The root seed is (S << 64) | (0x6F707573_00000000 + w). It feeds a
`DeterministicSeeder<DefaultRandomGenerator>`, which hands out these sub-seeds in order:
the secret-key generator, the BSK encryption generator, the KSK encryption generator, the
input encryption generator and a message stream (splitmix64, value mod 16). The probes
continue on the message stream. Keys are generated in shortint's order: the small LWE key
first, then the GLWE key (`shortint/client_key/atomic_pattern/ks32.rs:36-57`). The BSK uses
`par_allocate_and_generate_new_lwe_bootstrap_key`, which forks its generator per GGSW, so
the result is independent of thread count. Two runs with the same arguments give
byte-identical files (`evidence/stage0/oracle_determinism.log`).

## 2. Encoding, encryption and decryption

* Encoding: plaintext = m · Δ with Δ = 2^59 for m ∈ [0,16). The most significant bit is the
  padding bit and stays 0 (`shortint/encoding.rs:13-30`, `:78-87`). Δ is computed as
  (2^62 / 16) · 2.
* Encryption under the big key: the mask a ∈ (Z/2^64)^{kN} is uniform from the CSPRNG,
  e ← TUniform(17) (the *glwe* noise distribution, because the encryption key choice is Big:
  `shortint/client_key/atomic_pattern/ks32.rs:315-323`,
  `shortint/client_key/atomic_pattern/standard.rs:400`), and
  b = Σ a_i·s_i + m·Δ + e mod 2^64 (`core_crypto/algorithms/lwe_encryption.rs:107-113`).
  This is what shortint `unchecked_encrypt` does (`shortint/engine/client_side.rs:246-265`).
  The plain `encrypt` reduces m mod message_modulus = 4, so it cannot encrypt [0,16); that is
  why the oracle encrypts at core level.
* Phase: φ = b − Σ a_i·s_i mod 2^64.
* Decryption (`shortint/client_key/mod.rs:390`, `shortint/encoding.rs:89-95`,
  `core_crypto/algorithms/misc.rs:6-17`): m' = (⌊φ/Δ⌋ + [φ mod Δ ≥ Δ/2]) mod 32. This rounds
  half up, with φ read as unsigned. The result includes the padding bit, so a correct value is
  in [0,16). The decryption succeeds iff the signed error φ − Δ·f(m) lies in [−2^58, 2^58).

## 3. Keyswitch (big key, u64, dim kN → small key, w bits, dim n)

### 3.1 The signed decomposer (shared by the KS and the PBS)

Inputs: a value x on 64 bits (the KS decomposes the **u64** input mask even in ks32), a base
log β and a level count l. Let R = β·l (16 for the KS, 23 for the PBS) and B = 2^β.

1. **Round to the closest representable value and take the top R bits**
   (`core_crypto/commons/math/decomposition/decomposer.rs:156-185`, `init_decomposer_state`):
   * y = x >> (64 − R − 1), the top R+1 bits.
   * rb = y & 1, the rounding bit: the first bit below the kept part.
   * y = (y + 1) >> 1. This rounds half up to R bits.
   * y = y mod 2^R. A carry out of the top is dropped.
   * **Balance step**: if y > 2^(R−1), or if y = 2^(R−1) and rb = 1, set the state to
     s = y − 2^R (negative). Otherwise s = y. This follows
     `balanced_rounding_condition_bit_trick` at `decomposer.rs:61` and the subtraction at
     `decomposer.rs:184`. The state is held as a two's-complement u64.
2. **Extract digits, least significant first**
   (`core_crypto/commons/math/decomposition/iter.rs:103-119` and `:141-151`). Repeat l times:
   * d = s mod B (the low β bits, read as unsigned);
   * s = s >> β (arithmetic shift);
   * **carry**: if d > B/2, or if d = B/2 and (s mod B) ≥ B/2 (that is, the top bit of the
     *next* raw digit is set; see the comment above `decomposition_bit_trick`,
     `iter.rs:121-137`), set d = d − B and s = s + 1;
   * emit d. Each digit is in [−B/2, B/2].
   The carry left after the last (most significant) digit is discarded.
3. **Level numbering**: the first digit produced is decomposition level **j = l**, the least
   significant, with weight q/B^l. The last is j = 1, the most significant, with weight q/B.
   The iterator starts with `current_level = l` and labels each term `current_level + 1` after
   decrementing (`iter.rs:48`, `iter.rs:115`). Then Σ_j d_j · 2^(64 − β·j) ≡ closest(x) mod 2^64
   (`core_crypto/commons/math/decomposition/term.rs:49`).

### 3.2 KSK layout

KSK[i][t] is an LWE encryption under the small key of the plaintext
s_big[i] · 2^(w − β_ks·j), with **j = l_ks − t**. Stored index t = 0 holds the least
significant level (j = l_ks, weight 2^(w−16)) and t = l_ks − 1 holds j = 1 (weight 2^(w−4)).
Generation iterates levels l..1 in reverse (`core_crypto/algorithms/lwe_keyswitch_key_generation.rs:174-188`),
using `to_recomposition_summand` in the output word size w. In ks32 the key bit is first cast
to u32, so the plaintext is s·2^(32−4j) mod 2^32. The noise is the lwe noise distribution,
drawn mod 2^w. The ordering means that the digit iterator (LSB first) and the stored levels
(t = 0 first) line up when zipped. Both KS loops depend on this
(`core_crypto/algorithms/lwe_keyswitch.rs:212-226` and `:432-446`).

### 3.3 Keyswitch formula

    out = (0, …, 0, b')  −  Σ_{i=0}^{kN−1} Σ_{j=1}^{l_ks} d_{i,j} · KSK[i][l_ks − j]   (mod 2^w, wrapping)

Here d_{i,j} are the digits of the u64 input mask a_i (section 3.1, β = 4, l = 4, so R = 16:
the **top 16 bits of the 64-bit a_i**). Each digit is used as a w-bit two's-complement
multiplier: in ks32, `decomposed.value()` (u64) is cast to u32 (`lwe_keyswitch.rs:443`).

The body term b' depends on the variant:
* **ks32**: b' = closest representable of b on 32 bits, shifted down:
  b' = ((b >> 31) + 1) >> 1, truncated to u32. This rounds half up to the top 32 bits, and
  2^32 wraps to 0 (`lwe_keyswitch.rs:411-424`, using `native_closest_representable` at
  `decomposer.rs:25-49` with R = 32, l = 1).
* **classic**: b' = b, copied unchanged. The output modulus is native 2^64, so there is no
  rounding (`lwe_keyswitch.rs:189-204`).

shortint calls `keyswitch_lwe_ciphertext_with_scalar_change` for ks32
(`shortint/atomic_pattern/ks32.rs:161`) and `keyswitch_lwe_ciphertext` for classic
(`shortint/atomic_pattern/standard.rs:169`).

## 4. Centered-mean modulus switch (w bits → log2(2N) = 12 bits)

Let L = 12 (`PolynomialSize::to_blind_rotation_input_modulus_log` = log2 N + 1,
`core_crypto/commons/parameters.rs:163`) and sh = w − L (20 for ks32, 52 for classic).
Input: the KS output (a_0..a_{n−1}, b) mod 2^w. The modulus switch is selected by
`ModulusSwitchConfiguration::CenteredMeanNoiseReduction`
(`shortint/server_key/modulus_switch_noise_reduction.rs:355`). It calls
`lwe_ciphertext_centered_binary_modulus_switch` (`core_crypto/algorithms/modulus_switch.rs:35-102`)
and is evaluated lazily by `LazyStandardModulusSwitchedLweCiphertext`
(`core_crypto/entities/modulus_switched_lwe_ciphertext.rs:155-172`).

* **Rounding function** (`core_crypto/fft_impl/common.rs:10-23`):
  rnd(x) = ((x + 2^(sh−1)) mod 2^w) >> sh, which lies in [0, 2^L). This rounds half up, with
  wrap-around.
* **Mask**: ã_i = rnd(a_i). No correction is applied to the mask.
* **Body correction** (`modulus_switch.rs:56-102`):
  * For each i, the signed rounding error is err_i = signed_w( (rnd(a_i) << sh) − a_i ),
    with |err_i| ≤ 2^(sh−1).
  * tfhe-rs computes Σ err_i / 2 exactly in w-bit arithmetic as follows. It sums
    h_i = trunc(err_i / 2), truncating toward zero (Rust signed `/`). Separately it sums
    δ_i = 2·h_i − err_i ∈ {−1, 0, +1}, giving D = Σ δ_i. The result is
    S = Σ h_i − trunc(D / 2).
  * Closed form, used by our independent check: let E = Σ err_i (an exact integer). Then
    D = (#odd negative err_i) − (#odd positive err_i), and
    **S = E/2 if E is even, and S = (E + sign(D))/2 if E is odd**. E and D always have the
    same parity. So the half that is lost goes toward the side that has more odd-signed
    errors; this is not round-half-up of E/2.
  * The half-case constant is H = 2^(sh−1), which is half of one output step.
  * correction = S − H mod 2^w.
* **Body**: b̃ = rnd(b + S − H). Because rnd adds +H before shifting, this is equal to
  **b̃ = ((b + S) mod 2^w) >> sh**, a *floor* of the corrected body.
* Output (`ref_ms.u32`): ã_0..ã_{n−1}, b̃. All values are in [0, 2N) = [0, 4096).

Effect: the phase after the switch, b̃ − Σ ã_i·s_i mod 2N, has its expected value shifted
by −1/2 step. That centres the decision window [−64, 64) of the redundant LUT
(section 6), whose midpoint is −0.5.

## 5. Bootstrap key layout (bsk.u64) and the GGSW convention

`bsk.u64` is `LweBootstrapKey::as_ref()` verbatim: n GGSW ciphertexts, one per small-key bit
s_i, in key order. Each GGSW is l_pbs level matrices. Each level matrix is k+1 rows. Each row
is a GLWE ciphertext of k+1 polynomials (masks A_0..A_{k−1}, then the body B), with N
coefficients each. Index: `bsk[i][t][r][c][coef]`.

* **Level**: stored level index t holds decomposition level **j = l_pbs − t**
  (`core_crypto/algorithms/ggsw_encryption.rs:144`). Level t = 0 is the least significant.
  With l_pbs = 1 there is a single level, j = 1, with gadget weight g = q/B = 2^(64−23) = 2^41.
* **Factor**: factor = (−s_i) · 2^(64 − β·j) mod 2^64. Note the negation
  (`ggsw_encryption.rs:20-44`).
* **Row r < k** (`ggsw_encryption.rs:377-396`): a GLWE encryption of the polynomial
  factor·S_r = −s_i·g·S_r.
* **Row r = k** (`ggsw_encryption.rs:397-411`): a GLWE encryption of the constant polynomial
  −factor = +s_i·g, at coefficient 0 only.
* A GLWE encryption of the plaintext polynomial P is (A_0..A_{k−1}, B = Σ_c A_c·S_c + P + E),
  with E ← TUniform(17) per coefficient and A uniform.

The oracle checks this layout by decrypting every row of six GGSWs: the phase minus the
expected plaintext stays within ≤ 2^17 for every coefficient.

## 6. LUT, blind rotation, sample extraction

### 6.1 LUT (`shortint/engine/mod.rs:80-141`, called through `ServerKey::generate_lookup_table`, `shortint/server_key/mod.rs:844`)

* box = N / p = 2048 / 16 = 128 coefficients.
* LUT[x·box + c] = f(x)·Δ for x ∈ [0,16) and c ∈ [0, box). f(x) is not reduced, so it must
  already be in [0,16).
* Negate the first box/2 = 64 coefficients (two's complement).
* Rotate the whole array **left** by box/2: LUT'[c] = LUT[(c + 64) mod N].
* The mask polynomials are 0. `lut.u64` is LUT'.

Net effect: for a phase index φ̃ ∈ [0, N), LUT'[φ̃] = f(⌊(φ̃ + 64)/128⌋)·Δ, except that
φ̃ ∈ [N − 64, N) gives −f(0)·Δ. Negacyclic wrap-around turns that −f(0) into +f(0) for
φ̃ ∈ [2N − 64, 2N). Combined with the −1/2 shift of section 4, message x is decoded correctly
iff the MS-domain error e = φ̃ − 128·x lies in **[−64, 64)**.

### 6.2 Blind rotation (`core_crypto/fft_impl/fft64/crypto/bootstrap.rs:294-372`)

1. ACC = (0, …, 0, LUT') · X^(−b̃). The code calls `polynomial_wrapping_monic_monomial_div`
   with degree b̃ on every polynomial (`bootstrap.rs:325`). Multiplying by X^e for e ∈ [0, 2N)
   is a negacyclic rotation: coefficient c moves to c+e, and its sign flips each time the
   index passes N.
2. For i = 0..n−1, with ã_i taken from the MS output, skipping i if ã_i = 0 (`bootstrap.rs:335`):
   * T = ACC · X^(ã_i) − ACC, for each of the k+1 polynomials (`bootstrap.rs:348`);
   * ACC = ACC + ExtProd(GGSW_i, T) (`bootstrap.rs:357`).
3. ExtProd(GGSW, T) (`core_crypto/fft_impl/fft64/crypto/ggsw.rs:483-602`): decompose every
   coefficient of every polynomial T_r (r = 0..k; the body is r = k) with the signed
   decomposer of section 3.1 (β = 23, l = 1). For level j this gives a digit polynomial
   D_r^(j) with coefficients in [−2^22, 2^22]. The levels come in the same order as the stored
   level matrices (`ggsw.rs:529-538`), and row r of the level matrix is paired with component r
   of T (`ggsw.rs:552-555`):

       ExtProd = Σ_j Σ_{r=0}^{k} D_r^(j) · GGSW[l−j][r]       (a GLWE: k+1 polynomials)

   The phase of the result is Σ_r D_r·(−s_i g S_r) + D_k·(s_i g) ≈ s_i·(T_k − Σ_r T_r S_r)
   = s_i·phase(T). Therefore ACC ends up ≈ LUT' · X^(−b̃ + Σ ã_i s_i) = LUT' · X^(−φ̃).
   tfhe-rs computes these products with an **f64 FFT**, not exactly (section 7).

### 6.3 Sample extraction of coefficient 0 (`core_crypto/algorithms/glwe_sample_extraction.rs:89-146`)

The output is an LWE of dimension kN under s_big (section 1). For each mask polynomial A_r,
the output mask block is [A_r[0], −A_r[N−1], −A_r[N−2], …, −A_r[1]]. The output body is
B[0]. Equivalently, out_mask[r·N + c] = A_r[0] if c = 0, and −A_r[N − c] otherwise. Its
phase is the constant coefficient of the GLWE phase, which is LUT'[φ̃] plus noise.
shortint extracts degree 0 (`shortint/server_key/mod.rs:1598`).

## 7. What is and is not bit-exact

* **KS and MS are pure integer operations.** `verify-format` reproduces `ref_ks_out` and
  `ref_ms` bit for bit from `lwe_in` and `ksk` using only this document: 1000/1000 for ks32
  and 1000/1000 for classic.
* **The PBS output of tfhe-rs is not reproducible by an exact integer engine.** tfhe-rs
  computes each external product with a 64-bit-float FFT, so every coefficient of every
  product carries a rounding error.
  * For a single CMux (probe with M = 1), the exact-integer result differs from tfhe-rs in
    all 2049 coefficients, by up to about 2^40. The phase differs by about 2^44–2^46.
  * After two or more CMuxes, the small differences flip digit decisions in later
    decompositions, so the mask coefficients differ by up to 2^63, which looks random. The
    phase difference stays around 2^45–2^50.
  * The exact-integer PBS computed from `ref_ms` and `bsk.u64` still decrypts correctly on
    32/32 ciphertexts per variant (`verify-format --exact-pbs 32`).

  The bit-exact target for the RTL is therefore our own exact-integer model. tfhe-rs's PBS
  output can only be compared **after decryption**: the decrypted value must match, and the
  noise statistics must be close.

  The single-CMux probe has a 2^40 difference, against about 2^63 if any convention (level
  order, row order, sign, rotation direction, extraction pattern) were wrong. This confirms
  the conventions in sections 5 and 6.
* The FFT error is a visible part of tfhe-rs's output noise. tfhe-rs's formula with a 53-bit
  mantissa predicts log2 σ = 49.17, and we measure 49.18 (ks32) and 49.20 (classic). An
  exact-integer PBS removes the FFT term. That changes only the PBS output noise, not the
  KS/MS noise that decides p_fail.
