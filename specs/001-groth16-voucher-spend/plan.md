# Implementation Plan: Voucher Spend

**Branch**: `001-groth16-voucher-spend` | **Date**: 2026-04-15 | **Spec**: [spec.md](spec.md)

## Summary

Implement the core voucher spend protocol: a customer's phone generates a Groth16 proof that a spend is valid (within cap, authentic certificate, correct counter update), a coalition supermarket submits the transaction on-chain, and the customer's committed spend counter is updated. The proof embeds issuer signature verification, counter arithmetic, range check, and Poseidon commitment binding in a single circuit.

## Technical Context

**Language/Version**: Haskell (GHC 9.10+) for off-chain, Aiken (Plutus V3) for on-chain, Circom 2 for circuits, Rust for FFI
**Primary Dependencies**: cardano-node-clients (tx construction), blst (BLS12-381 point compression), snarkjs (proof generation), circomlib (Poseidon, comparators)
**Storage**: On-chain UTXO per user (committed counter), off-chain certificates on user device
**Testing**: HSpec (Haskell), Aiken check (on-chain), snarkjs verify (circuits)
**Target Platform**: Cardano L1 (Plutus V3)
**Project Type**: Protocol library (on-chain validators + off-chain tooling + ZK circuits)
**Performance Goals**: Groth16 verification within 25% of per-transaction budget (~2.5B CPU units)
**Constraints**: Single transaction resource limits (10B CPU, 14M memory), BLS12-381 curve only
**Scale/Scope**: Single-issuer single-user MVP first, multi-issuer and shared trie later

## Constitution Check

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Coalition, Not Silos | PASS | Multi-issuer support in circuit design (issuer VK as private input) |
| II. User Has No Wallet | PASS | Supermarket submits all transactions |
| III. Zero Infrastructure | PASS | Coalition members need only a signing key and chain reader |
| IV. Smart Contract as Trust | PASS | Validator verifies proof, checks issuer list |
| V. Privacy by Default | PASS | Only spend amount public, cap/balance/total hidden |
| VI. Proof Soundness | PASS | Single Groth16 circuit with embedded signature verification |
| VII. Monotonic State | PASS | Cap up only, spent up only, enforced by circuit |
| VIII. On-Chain Spending | PASS | All spends settle on L1 |
| IX. Earn and Spend | DEFERRED | Earning (certificate issuance) is a separate spec |
| X. Correct Before Optimized | PASS | Starting with one UTXO per user, single issuer |
| XI. Nix-First | PASS | All tooling in flake.nix |

## Project Structure

### Documentation (this feature)

```text
specs/001-groth16-voucher-spend/
├── spec.md
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
└── contracts/
    └── spend-proof-format.md
```

### Source Code (repository root)

```text
circuits/
├── voucher_spend.circom       # ZK circuit (Poseidon + range + signature)
├── generate_proof.js          # Proof generation script (snarkjs)
└── build/                     # Compiled circuit + trusted setup artifacts

onchain/
├── aiken.toml
├── validators/
│   └── voucher_spend.ak       # Spend validator (Groth16 verify + state machine)
└── lib/
    └── voucher/
        ├── groth16.ak         # Groth16 pairing verification
        └── types.ak           # On-chain data types

offchain/
├── cardano-bbs.cabal
├── cbits/
│   └── groth16-ffi/           # Rust point compression (blst)
├── src/
│   └── Cardano/Groth16/
│       ├── FFI.hs             # Rust FFI bindings
│       ├── Types.hs           # snarkjs JSON types
│       ├── Compress.hs        # Point compression pipeline
│       ├── Serialize.hs       # PlutusData CBOR encoding
│       └── Prove.hs           # Proof generation wrapper
└── test/
    └── Groth16Spec.hs         # Round-trip tests
```

**Structure Decision**: Three-layer architecture matching the three concerns: ZK circuits (Circom), on-chain validation (Aiken), off-chain tooling (Haskell + Rust FFI). Existing code from cardano-bbs-next to be migrated.

## Complexity Tracking

No constitution violations. No complexity justification needed.
