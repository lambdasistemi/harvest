# Research: Voucher Spend

## R1: Signature Verification Inside Groth16 Circuit

**Question**: How to verify the issuer's certificate signature inside the Circom circuit?

**Decision**: Use EdDSA (Baby Jubjub) for issuer signatures. circomlib provides `EdDSAVerifier` which operates on the Baby Jubjub curve embedded in BLS12-381's scalar field.

**Rationale**: EdDSA verification in Circom is well-tested (circomlib), adds ~3000 constraints (small relative to circuit budget), and operates natively in the circuit's field. ECDSA would be far more expensive (~100k constraints). BLS signatures would require pairing operations inside the circuit (not feasible).

**Alternatives considered**:
- Poseidon-based MAC: simpler but requires a shared secret between issuer and user — not suitable for a coalition where the user presents certificates to any member.
- ECDSA (secp256k1): circomlib has it but ~100k constraints, too expensive.
- BLS signatures: would need pairing in-circuit, not practical in Circom.

**Impact on circuit**: The circuit grows from ~519 constraints (current Poseidon-only) to ~4000 constraints with EdDSA verification. Still well within Groth16 efficiency range. Proof generation stays under 1 second on commodity hardware.

## R2: User Identity Binding

**Question**: How is the user identified across certificates and on-chain state?

**Decision**: The user is identified by a Poseidon hash of a secret known only to them (`user_secret`). The hash `user_id = Poseidon(user_secret)` is public (appears in certificates and on-chain). The secret is private (never leaves the phone).

**Rationale**: The user has no blockchain wallet, so we can't use a public key. A Poseidon hash of a secret is cheap to verify inside the circuit (already using Poseidon), and the secret acts as the user's "private key" for the voucher system.

**Alternatives considered**:
- Public key (Ed25519): requires the user to have a key pair and sign transactions — violates "user has no wallet."
- Random ID: not provable inside the circuit — anyone could claim to be any user.

## R3: Circuit-Field Compatibility

**Question**: Does circomlib's EdDSA work on BLS12-381's scalar field?

**Decision**: Yes. When compiling with `--prime bls12381`, Circom operates over BLS12-381's scalar field. The Baby Jubjub curve used by circomlib's EdDSA is defined as an embedded curve within the circuit's base field. The Baby Jubjub parameters depend on the prime — circomlib auto-generates the correct parameters for the selected prime.

**Rationale**: Verified that `circom --prime bls12381` compiles circomlib's Poseidon templates correctly (tested in prototype). EdDSA uses the same field arithmetic.

**Risk**: Need to verify that circomlib's EdDSA Baby Jubjub generators are correctly parameterized for BLS12-381. Test: compile a circuit with EdDSAVerifier using `--prime bls12381` and run a sign/verify round-trip.

## R4: On-Chain Verification Cost

**Question**: Does the Groth16 proof verification fit within Plutus V3 budget?

**Decision**: Yes. Measured at ~2.5B CPU units (~25% of 10B limit). The circuit size does not affect on-chain verification cost — Groth16 proofs are constant size regardless of constraint count.

**Rationale**: The on-chain verification is 4 miller loops + 2 mul_ml_result + 1 final_verify + vk_x computation (3 scalar muls for 3 public inputs). This is fixed cost. More public inputs would increase vk_x computation linearly, but 3 inputs is cheap.

**Alternatives considered**: None needed — the budget is comfortable.

## R5: Existing Prototype

**Question**: What exists already and what needs to be built?

**Decision**: Significant prototype exists in `cardano-bbs-next`. To be migrated to `cardano-vouchers`.

**What works (tested)**:
- Circom circuit compiles on BLS12-381 with Poseidon commitments (519 constraints)
- Proof round-trip: generate + verify passes (snarkjs)
- Aiken Groth16 verifier compiles (4 pairings via BLS12-381 builtins)
- Rust FFI point compression (blst) — compiles and tested
- Haskell: JSON parsing, compression, PlutusData CBOR — 9/9 tests pass

**What needs building**:
- EdDSA signature verification in the circuit (R1)
- User identity binding in the circuit (R2)
- Issuer verification key as circuit input (coalition check)
- Transaction construction and submission via cardano-node-clients
- End-to-end test: generate proof → compress → serialize → submit → confirm on testnet

## R6: Trusted Setup Distribution

**Question**: How do issuers distribute proving keys to users?

**Decision**: Each issuer runs a trusted setup for the shared circuit (same circuit, different setup). The proving key is published alongside the issuer's verification key. Users download it when they first receive a certificate from that issuer.

**Rationale**: The proving key is public (no secrets). The verification key is already on-chain. The proving key can be served from a simple HTTPS endpoint or bundled with the certificate.

**Alternatives considered**:
- Universal setup (Halo2): no trusted setup needed but verification is more expensive on-chain and the tooling is less mature for Cardano.
- Shared setup across all issuers: simpler but couples issuers — one compromised setup compromises all.
