# Work In Progress — Cardano Vouchers

Last updated: 2026-04-15

## Project Goal

A loyalty coalition protocol on Cardano. Multiple businesses form a coalition, each issuing voucher certificates to customers. Customers spend vouchers at any coalition member using zero-knowledge proofs. One wallet, every loyalty program.

The user has no Cardano wallet. The supermarket submits all transactions. Privacy is enforced by Groth16 proofs — on-chain observers see only the spend amount, never the balance or cap.

## Architecture

```
User's Phone                    Supermarket POS              Cardano L1
─────────────                   ───────────────              ──────────
Certificates (off-chain)        Signing key                  Coalition validator
  - user_id, cap, signature     Wallet (ADA)                 Accepted issuer list
  - issuer signature                                         User entries:
Private state                                                  user_id → commit(spent)
  - running total
  - randomness                  Submits tx with              Groth16 proof verified
  - proving key                 user's ZK proof              Counter updated
```

## What Works

### Circuit (Circom on BLS12-381)

**File**: `circuits/voucher_spend.circom`

The circuit proves all of the following in a single Groth16 proof:

| Constraint | What it proves |
|---|---|
| `user_id == Poseidon(user_secret)` | User identity |
| `cert_hash == Poseidon(user_id, cap, nonce)` | Certificate authenticity |
| `S_new == S_old + d` | Counter arithmetic |
| `S_new <= cap` | No overspend (32-bit range) |
| `commit_old == Poseidon(S_old, r_old)` | Old commitment binding |
| `commit_new == Poseidon(S_new, r_new)` | New commitment binding |

- **999 non-linear constraints**, 5 public inputs, 7 private inputs
- Compiles with `circom --prime bls12381`
- Proof round-trip verified: `node generate_proof.js` → "Verification: VALID"
- Trusted setup with contribution produces non-trivial IC points

**Limitation**: Certificate authentication currently uses a Poseidon commitment scheme (`cert_hash`), not a digital signature. This requires publishing each `cert_hash` on-chain — one transaction per certificate issuance. This violates the constitution's principle that transactions happen only on spending. The Jubjub EdDSA port is now working (see below) and can replace `cert_hash` with off-chain signed certificates.

### On-Chain Validator (Aiken, Plutus V3)

**Files**: `onchain/validators/voucher_spend.ak`, `onchain/lib/voucher/`

- Groth16 pairing verification using BLS12-381 builtins:
  - `bls12_381_miller_loop` (4 calls)
  - `bls12_381_mul_miller_loop_result` (2 calls)
  - `bls12_381_final_verify` (1 call)
- Estimated on-chain cost: ~2.5B CPU units (~25% of per-transaction budget)
- State machine: consumes user UTXO, verifies proof, outputs updated datum
- No user signature required (the ZK proof IS the authentication)
- Parameterized by verification key (one per issuer trusted setup)

**Types**:
- `VoucherDatum { user_id: Int, commit_spent: Int }`
- `SpendRedeemer { d: Int, commit_spent_new: Int, cert_hash: Int, proof: Groth16Proof }`
- `Groth16Proof { a: ByteArray, b: ByteArray, c: ByteArray }` (compressed G1/G2 points)

### Rust FFI (blst)

**Files**: `offchain/cbits/groth16-ffi/`

- `groth16_g1_compress`: affine (x,y) integers → 48-byte compressed G1 point
- `groth16_g2_compress`: affine (x0,x1,y0,y1) integers → 96-byte compressed G2 point
- Uses the `blst` crate (BLS12-381 library by Supranational)
- Builds as a cdylib, linked via Haskell FFI

### Haskell Off-Chain Library

**Files**: `offchain/src/Cardano/Groth16/`, `offchain/src/Cardano/PlutusData.hs`

| Module | Purpose | Status |
|---|---|---|
| `Cardano.PlutusData` | PlutusData CBOR encoding/decoding (standalone, no BBS deps) | Working |
| `Cardano.Groth16.FFI` | Foreign imports for Rust point compression | Working |
| `Cardano.Groth16.Types` | snarkjs JSON types + Aeson instances (proof, VK, G1/G2 affine) | Working |
| `Cardano.Groth16.Compress` | snarkjs affine coords → compressed BLS12-381 points | Working |
| `Cardano.Groth16.Serialize` | PlutusData encoding for all on-chain types | Working |
| `Cardano.Groth16.Prove` | Subprocess wrapper for snarkjs proof generation | Written, untested |

**Tests**: 9/9 pass (JSON parsing, point compression byte sizes, CBOR round-trips for proof, VK, redeemer, datum)

### Nix

**File**: `flake.nix`, `nix/project.nix`, `nix/checks.nix`, `nix/apps.nix`

| Flake output | What it builds |
|---|---|
| `packages.groth16-ffi` | Rust crate via `rustPlatform.buildRustPackage` |
| `packages.circuit` | Circom compilation via `buildNpmPackage` (npm deps prefetched) |
| `checks.library` | Haskell library via `haskell.nix` (cabalProject', linked to groth16-ffi) |
| `checks.unit-tests` | Haskell test binary (compiles, doesn't run in sandbox yet — needs circuit artifacts) |
| `checks.groth16-ffi` | Rust crate compiles |
| `checks.circuit` | Circuit compiles on BLS12-381 |
| `checks.lint` | fourmolu + hlint |
| `checks.aiken-check` | Aiken validators compile |
| `apps.lint` | Runnable lint check |
| `devShells.default` | Full dev environment via haskell.nix shell |

IOG binary cache configured for haskell.nix dependencies.

### Specs

**Directory**: `specs/001-groth16-voucher-spend/`

- `spec.md` — 5 user stories (spend, cross-member, no wallet, sequential, multi-issuer), 12 requirements, edge cases
- `plan.md` — technical context, constitution check, project structure
- `research.md` — 6 research items (signature scheme, user identity, field compatibility, cost, prototype, trusted setup)
- `data-model.md` — entities, state transitions, full circuit input/output spec
- `contracts/spend-proof-format.md` — phone↔supermarket interface
- `quickstart.md` — step-by-step dev setup
- `tasks.md` — 48 tasks across 8 phases
- `checklists/requirements.md` — all items pass

## What Doesn't Work Yet

### Jubjub EdDSA in Circuit (Critical Blocker)

**Files**: `circuits/lib/eddsa_jubjub.circom`, `circuits/lib/jubjub_full.circom`, etc.

**The problem**: circomlib's EdDSA uses Baby Jubjub (BN128 constants). Compilation hangs on BLS12-381 because the curve parameters are invalid in that field.

**What we did**: Ported all circomlib templates to use the Jubjub curve (Zcash's twisted Edwards curve over BLS12-381's scalar field):

| Parameter | Value |
|---|---|
| Field | BLS12-381 scalar: `52435875175126190479447740508185965837690552500527637822603658699938581184513` |
| a | -1 |
| d | `19257038036680949359750312669786877991949435402254120286184196891950884077233` |
| Generator x | `8076246640662884909881801758704306714034609987455869804520522091855516602923` |
| Generator y | `13262374693698910701929044844600465831413122818447359594527400194675274060458` |
| Base8 x | `52363696936650001301287582521711853146588465673974699354184720335305084401224` |
| Base8 y | `12024993157431732930272824407495979791132374572895036891122288541794509830761` |
| Subgroup order | `6554484396890773809930967563523245729705921265872317281365359162392183254199` |
| Cofactor | 8 |
| Montgomery A | 40962 |

All parameters mathematically verified (generator on curve, Base8 * subgroup_order = identity, Montgomery A = 2(a+d)/(a-d)).

**Ported files**:
- `jubjub_full.circom` — add, double, point check with Jubjub constants
- `montgomery_jubjub.circom` — Edwards↔Montgomery with Jubjub a, d
- `escalarmulany_jubjub.circom` — variable-base scalar mul (BabyAdd → JubjubFullAdd)
- `escalarmulfix_jubjub.circom` — fixed-base scalar mul (BabyAdd → JubjubFullAdd)
- `eddsa_jubjub.circom` — EdDSA-Poseidon verifier with Jubjub Base8 and subgroup order
- `jubjub_eddsa.js` — off-chain signing (keygen, sign with Poseidon hash)

**Current status**: WORKING. Templates compile (7132 constraints). Circuit witness generation passes for all tested messages.

**Root cause of previous failure**: The JS keygen was using `Base8` (subgroup generator) instead of `Gen` (a different subgroup point where `Base8 = 8*Gen`). The circuit follows circomlib's cofactor-clearing design (`8*A`), which assumes `A = sk*Gen` so that `8*A = sk*Base8`. With `A = sk*Base8`, the equation's right side was 8x too large.

**Secondary fix**: `escalarmulany_jubjub.circom` had Baby Jubjub's BASE8 (BN128 point) hardcoded as the zero-point fallback — replaced with Jubjub's BASE8.

**Note on Gen**: Gen is actually a subgroup generator (not a full-curve generator with order 8*ORDER). The EdDSA equation holds regardless since both Gen and Base8 are in the prime-order subgroup. The `8*A` step is a redundant scaling within the subgroup, not true cofactor clearing, but the math is correct.

**Validation** (`test_jubjub_validation.js`, 31/31 pass):
- Curve constants (on-curve, generator order, Base8 = 8*Gen)
- EdDSA equation verified algebraically in JS for 5 message values
- Circuit witness generation verified for 5 signatures

### Alternative: Halo2

If the Jubjub EdDSA port proves too fragile, the alternative is switching the proof system to Halo2:

- Halo2 circuits are written in Rust, not Circom
- The `ark-ed-on-bls12-381` crate provides Jubjub natively
- IOG's `plutus-halo2-verifier-gen` generates Aiken verifiers for Halo2 proofs
- Halo2 has no trusted setup (universal parameters)
- On-chain verification is more expensive than Groth16

### Transaction Construction

No cardano-node-clients integration yet. The Haskell library produces CBOR-encoded PlutusData for datum and redeemer, but doesn't construct or submit transactions.

### Nix Test Execution

The `checks.unit-tests` compiles the test binary but doesn't run the tests in the nix sandbox because the tests reference `../circuits/build/proof.json` which is generated by snarkjs (not a nix derivation). Need to wire the circuit derivation output into the test environment.

### External Test Vectors

The Aiken Groth16 verifier has not been validated against external test vectors (ak-381's 3_fac circuit, plutus-groth's 3 Haskell test cases). This is needed to confirm the pairing math is correct independently of our own circuit.

## Open Design Questions

### Settlement Timing at Checkout

L1 settlement takes ~5 minutes for reasonable confidence. At a physical checkout, the customer can present the same spend proof to two cashiers at different shops before either transaction confirms. Every mitigation explored (mempool, freeze tokens, pre-commitment) either requires coalition infrastructure (violates the constitution) or shifts the double-spend window rather than eliminating it.

**Current position**: The protocol is correct for scenarios where settlement delay is acceptable (online orders, pre-committed spends). Physical point-of-sale remains an open UX problem. Documented in the constitution (v4, "Open Design Problem" section).

### Scaling

L1 throughput (~15 spends/minute with Groth16 verification) limits volume. Millions of daily spends require an off-chain layer. Hydra was explored but rejected (all participants must be online; one offline member stalls the head). A centralized collector/batcher was explored but has censorship risks (can omit spends, benefiting colluding users). No satisfactory L2 solution identified yet.

**Current position**: Start on L1, accept the throughput limit. Scaling is a future problem that depends on the Cardano L2 landscape maturing.

## File Map

```
cardano-vouchers/
├── circuits/
│   ├── voucher_spend.circom          # Main ZK circuit (999 constraints)
│   ├── generate_proof.js             # Proof generation + verification
│   ├── test_eddsa_roundtrip.js       # EdDSA test (currently failing)
│   ├── package.json                  # npm deps (snarkjs, circomlib, circomlibjs)
│   ├── lib/
│   │   ├── jubjub.circom             # Simple Jubjub add/dbl
│   │   ├── jubjub_full.circom        # Full Jubjub (drop-in for babyjub.circom)
│   │   ├── montgomery_jubjub.circom  # Edwards↔Montgomery with Jubjub constants
│   │   ├── escalarmulany_jubjub.circom  # Variable-base scalar mul
│   │   ├── escalarmulfix_jubjub.circom  # Fixed-base scalar mul
│   │   ├── eddsa_jubjub.circom       # EdDSA-Poseidon verifier
│   │   └── jubjub_eddsa.js           # Off-chain signing (JS)
│   └── build/                        # Generated (gitignored): r1cs, wasm, zkey, vk, proofs
├── onchain/
│   ├── aiken.toml
│   ├── validators/
│   │   └── voucher_spend.ak          # Spend validator (Groth16 + state machine)
│   └── lib/voucher/
│       ├── groth16.ak                # Groth16 pairing verification
│       └── types.ak                  # On-chain data types
├── offchain/
│   ├── cardano-vouchers.cabal
│   ├── cabal.project
│   ├── cbits/groth16-ffi/            # Rust: BLS12-381 point compression
│   ├── src/
│   │   ├── Cardano/PlutusData.hs     # PlutusData CBOR (standalone)
│   │   └── Cardano/Groth16/
│   │       ├── FFI.hs                # Rust FFI bindings
│   │       ├── Types.hs              # snarkjs JSON types
│   │       ├── Compress.hs           # Point compression pipeline
│   │       ├── Serialize.hs          # PlutusData encoding
│   │       └── Prove.hs              # snarkjs subprocess wrapper
│   └── test/
│       ├── Main.hs
│       └── Groth16Spec.hs            # 9 tests (all pass)
├── nix/
│   ├── project.nix                   # haskell.nix cabalProject'
│   ├── checks.nix                    # library, unit-tests, lint
│   └── apps.nix                      # runnable wrappers
├── specs/001-groth16-voucher-spend/
│   ├── spec.md                       # Feature specification
│   ├── plan.md                       # Implementation plan
│   ├── research.md                   # Research decisions
│   ├── data-model.md                 # Entity model + circuit I/O
│   ├── tasks.md                      # 48 tasks, 8 phases
│   ├── quickstart.md                 # Dev setup guide
│   └── contracts/
│       └── spend-proof-format.md     # Phone↔supermarket interface
├── .specify/memory/constitution.md   # Project constitution (v4)
├── .github/workflows/ci.yml         # CI: nix checks
├── flake.nix                         # Nix flake (haskell.nix + aiken + circom + rust)
├── justfile                          # Dev recipes
└── WIP.md                            # This file
```

## Research Log

### ZK Proof System Selection

**Question**: Which proof system for on-chain verification on Cardano?

**Decision**: Groth16 on BLS12-381.

**Rationale**: Plutus V3 provides BLS12-381 pairing builtins (CIP-381). Groth16 verification is a single pairing equation — 4 miller loops, 2 mul_ml_result, 1 final_verify. Constant-size proof (3 curve points, ~192 bytes) regardless of circuit complexity. On-chain cost ~25% of transaction budget. The ak-381 library from Modulo-P proved Groth16 verification works on Cardano mainnet.

**Alternatives rejected**:
- **Halo2**: No trusted setup (advantage), but verification is more expensive on-chain. plutus-halo2-verifier-gen exists but is newer and less battle-tested. Remains a fallback if Groth16 limitations become blocking.
- **PLONK**: Similar to Halo2 tradeoffs. plutus-plonk-example exists as proof of concept.
- **BBS+ selective disclosure**: Originally considered for credential verification. Rejected because we need arithmetic proofs (counter + range check), not just attribute disclosure.
- **Raw BLS12-381 primitives**: Pedersen commitments work on G1 (scalar mul + add), but range proofs require a structured proof system — raw primitives can't prove `S <= C` without revealing both values.

### Commitment Scheme Selection

**Question**: Pedersen commitments (elliptic curve) or Poseidon hash commitments?

**Decision**: Poseidon hash.

**Rationale**: The circuit targets BLS12-381's scalar field. Poseidon is pure field arithmetic — no curve operations needed inside the circuit. Each Poseidon hash adds ~250 constraints. Pedersen commitments (on an embedded curve) would require curve point operations inside the circuit, adding thousands of constraints and the same curve-compatibility issues we face with EdDSA.

**Tradeoff**: Poseidon commitments are binding and hiding (with randomness), but not additively homomorphic. We don't need homomorphic properties — the counter update is proven inside the circuit, not verified algebraically on the commitments.

### Signature Scheme Selection

**Question**: How to authenticate voucher certificates inside the ZK circuit?

**Explored options**:

| Approach | Constraints | Status |
|---|---|---|
| EdDSA on Baby Jubjub (circomlib) | ~3000 | BN128-only. Compilation hangs on BLS12-381. |
| EdDSA on Jubjub (ported) | ~7000 | Compiles on BLS12-381. Verification fails (bug in scalar mul). WIP. |
| Poseidon commitment (cert_hash) | ~250 | Works. But requires on-chain write per certificate. |
| ECDSA (secp256k1, circomlib) | ~100k | Too expensive. |
| BLS signatures in-circuit | Millions | Requires pairing in-circuit. Not feasible. |
| RSA in-circuit | ~100k | Too expensive. |

**Current decision**: Poseidon commitment as interim. Jubjub EdDSA as target (WIP). Halo2 as fallback.

**Key finding**: circomlib is fundamentally tied to BN128 in multiple templates (Baby Jubjub constants, `Num2Bits_strict` 254-bit hardcoding, `AliasCheck` 254-bit). Porting to BLS12-381 requires patching not just the curve templates but also bit-manipulation utilities.

### User Identity

**Question**: How is the user identified without a Cardano wallet?

**Decision**: `user_id = Poseidon(user_secret)`. The user holds a secret on their phone. The hash is public (appears on-chain and in certificates). The circuit proves knowledge of the secret.

**Rationale**: No wallet, no public key, no signing key. The Poseidon hash is cheap (1 constraint in the circuit). The secret acts as the user's "private key" for the voucher system.

### On-Chain State Model

**Question**: One UTXO per user, or shared Merkle Patricia Trie?

**Decision**: One UTXO per user for MVP. Shared trie (nested: issuer → user → counter) as future optimization.

**Rationale**: Per-user UTXOs are simpler — no contention, no Merkle proofs inside the circuit. The trie model is more space-efficient and enables multi-issuer spends in one transaction, but adds complexity (trie proof in circuit, UTXO contention requiring a batcher).

### Double-Spend Prevention

**Question**: How to prevent the user from spending the same balance twice at different shops?

**Explored approaches**:

| Approach | Result |
|---|---|
| Global mempool (lock service) | Works but requires coalition infrastructure |
| Freeze-and-confirm (two-phase) | Shifts problem to redemption side |
| Mint-and-burn tokens | Cashier gives discount before burn confirms |
| Physical tokens | Can be replicated to second phone |
| Hydra L2 | All participants must be online |
| Pre-commitment at shop entrance | Overcommit/undercommit complexity |
| UTXO contention (natural) | One tx succeeds, other fails. 20s+ window. |
| Batcher with per-user queue | Fast rejection but centralized |

**Current position**: UTXO contention provides natural prevention. The ~5 minute settlement window is accepted for the MVP. Physical point-of-sale timing remains an open design problem.

### Scalability

**Question**: Can this handle millions of daily spends?

**Analysis**: L1 throughput with Groth16 verification: ~3-4 spends per transaction (budget limited), ~20s blocks → ~10-15 spends/minute → ~20,000/day maximum on L1.

**Explored L2 options**:
- **Hydra**: Runs Plutus natively (same validators). But requires all participants online; one offline stalls the head. Delegated head topology (3-5 operator nodes, supermarkets as clients) partially mitigates this.
- **Off-chain batcher**: Verifies proofs off-chain, posts trie roots to L1. Fast but has censorship risk — the batcher can omit spends (benefiting colluding users who get the discount without their counter incrementing).
- **Certificate chain on user's phone**: Each spend produces a receipt that chains to the previous one. Forks are detectable. But detection requires shared state.

**Current position**: Start on L1. Scaling depends on Cardano's L2 maturation. The protocol is chain-agnostic — same proofs work on any chain with BLS12-381 pairing support.

### Circom Field Compatibility

**Question**: Does circomlib work correctly with `--prime bls12381`?

**Findings**:

| Template | BLS12-381 compatible? | Issue |
|---|---|---|
| Poseidon | Yes | Field-arithmetic only, no curve constants |
| LessEqThan / Comparators | Yes | Bit-level, works on any field |
| Num2Bits(n) | Yes | Generic for any n |
| Num2Bits_strict | No | Hardcoded 254 bits (BN128 field size) |
| AliasCheck | No | Hardcoded 254 bits |
| CompConstant | Partially | Logic is generic but used with BN128-specific constants |
| BabyAdd / BabyDbl | No | Hardcoded Baby Jubjub constants (a=168700, d=168696) |
| EscalarMulFix / EscalarMulAny | No | Uses BabyAdd internally |
| EdDSAPoseidonVerifier | No | Uses all of the above |
| Edwards2Montgomery | Yes | Formulas are generic |
| MontgomeryAdd / MontgomeryDouble | No | Hardcoded a=168700, d=168696 for A,B computation |

**Impact**: Any circuit that uses only Poseidon + Comparators works fine on BLS12-381. Anything involving curve operations (EdDSA, scalar multiplication) needs porting.

### Aiken Builtin Discovery

**Question**: Does Aiken expose `bls12_381_mul_ml_result` for Groth16 verification?

**Journey**:
1. First tried `builtin.bls12_381_mul_ml_result` — not found
2. Tried `builtin.bls12_381_mulMlResult` (camelCase) — not found
3. Discovered the correct name: `builtin.bls12_381_mul_miller_loop_result`
4. Available in Aiken v1.1.21 (our version)

**Lesson**: Aiken's builtin names don't match the CIP-381 names exactly. The stdlib doesn't wrap this function (only `miller_loop` and `final_exponentiation` are in the pairing module). Direct builtin access is required.

### Certificate Authentication Without Signatures

**Question**: If EdDSA doesn't work in the circuit, how to authenticate certificates?

**Current approach**: Poseidon commitment. The issuer computes `cert_hash = Poseidon(user_id, cap, nonce)` and gives `(user_id, cap, nonce)` to the user. The user proves knowledge of the preimage inside the circuit. Only the issuer (who chose the nonce) and the user (who received it) can produce a valid proof.

**Problem**: Each `cert_hash` must be published on-chain for the validator to check against. This creates an on-chain transaction per certificate issuance, violating the principle that transactions happen only on spending.

**Mitigations considered**:
- Batch cert_hashes into a Merkle tree, publish one root — reduces to one tx per batch, but still requires on-chain writes for issuance
- Pre-publish a large tree of unused cert_hashes — wasteful, doesn't scale

**Real fix**: Jubjub EdDSA is now working. Integrate it into `voucher_spend.circom` to replace `cert_hash` with signature verification.

## Next Steps (Priority Order)

1. **Integrate EdDSA into voucher_spend circuit** — replace `cert_hash` commitment with Jubjub EdDSA signature verification. The issuer signs certificates off-chain, the circuit verifies the signature. No on-chain write needed for issuance.
2. **External Groth16 test vectors** — validate the Aiken verifier against ak-381 and plutus-groth test data.
3. **Wire nix test execution** — make `checks.unit-tests` run tests in the sandbox with circuit artifacts.
4. **Transaction construction** — integrate cardano-node-clients for building and submitting spend transactions.
5. **Testnet deployment** — deploy validator, create user UTXOs, submit spend transactions on preprod.
