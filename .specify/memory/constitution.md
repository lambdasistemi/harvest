# Cardano Vouchers Constitution

## Vision

A loyalty coalition protocol on Cardano. Multiple businesses form a coalition. Each member issues voucher certificates to customers. Customers spend vouchers at any coalition member. One wallet, every loyalty program.

New members get instant foot traffic on day one — existing coalition users walk in and spend vouchers before the new member has issued a single certificate. Every redemption is a real sale. The coalition is the growth flywheel.

## Core Principles

### I. Coalition, Not Silos

The protocol eliminates per-business loyalty silos. Any coalition member issues vouchers. Any coalition member accepts them. Users earn at one place, spend at another. The coalition is the product — not the individual issuer. Joining the coalition means adding a verification key to the on-chain list. That is the only integration step.

### II. User Device as State Store

The user's phone holds all private state: certificates, caps, randomness, proving keys. No server-side user databases. No accounts. The blockchain is the audit trail, the phone is the wallet. Issuers need only a signing key.

### III. Zero Infrastructure for Coalition Members

Coalition members need a signing key and a way to read the chain. No databases, no servers, no POS integrations beyond basic QR/NFC reading. The protocol must not require coalition members to run infrastructure.

### IV. Smart Contract as Trust Layer

Coalition members do not verify each other's certificates. The on-chain validator does. A fake certificate produces an invalid Groth16 proof. The transaction fails. Nobody loses anything. No APIs, no shared databases, no inter-member communication needed.

### V. Privacy by Default

User balances and voucher caps are never revealed on-chain. All on-chain data is commitments (Poseidon hashes) or zero-knowledge proofs. Only the spend amount per transaction is public. The issuer who tops up a user's cap knows that cap (they signed it), but on-chain observers learn nothing about balances.

### VI. Proof Soundness

No spend occurs without a valid Groth16 proof that the committed counter has not exceeded the hidden cap. A single Groth16 circuit handles everything: issuer signature verification, counter arithmetic, range check, and commitment binding. No second proof system is needed — the signature check is embedded in the circuit.

### VII. Monotonic State

Cap only grows (rewards). Spent only grows (redemptions). The invariant is always: spent <= cap. The gap is the user's available balance, known only to the user's phone. A new certificate always supersedes the old one with a higher cap. There is no revocation.

### VIII. On-Chain Spending

All voucher spends settle on L1. The spend transaction updates the user's committed counter on-chain. This is the only transaction type in the system. Certificate issuance and cap updates happen off-chain (signed by the issuer, stored on the user's phone). The on-chain state is the single source of truth for spend history.

### IX. Earn and Spend in One Visit

At the supermarket, the user can both spend existing vouchers and earn new ones. Spending is on-chain (Groth16 proof). Earning is off-chain (supermarket signs a new certificate with a higher cap). The user walks away with an updated on-chain committed counter and a new certificate.

### X. Correct Before Optimized

Start simple, prove correctness, then optimize. One UTXO per user before a shared trie. Single-issuer spends before multi-issuer. snarkjs before native prover. Every step end-to-end testable before the next.

### XI. Nix-First

All dependencies, builds, and CI are Nix-managed. The flake produces all derivations. No global installs, no version drift.

## Open Design Problem: Settlement Timing at Checkout

L1 settlement requires multiple confirmations (~5 minutes for reasonable confidence). At a physical checkout, this creates a window for double-spending: the user could present the same spend to multiple cashiers before any transaction is confirmed.

Explored and rejected approaches:
- **Mempool/lock service**: requires coalition infrastructure (violates Principle III)
- **Freeze-and-confirm two-step**: shifts double-spend problem to the redemption side
- **Mint-and-burn tokens**: cashier gives discount before burn confirms, same gap
- **Physical tokens**: can be replicated or stolen back
- **Hydra L2**: requires all participants online, stalls if one drops

Pre-commitment model (freeze before shopping) partially mitigates this but introduces overcommit/undercommit complexity.

This remains an open problem. The protocol is correct for scenarios where settlement time is acceptable (online orders, pre-commitment with sufficient lead time, low-value spends where the double-spend risk is accepted).

## Technology Stack

- **On-chain**: Aiken (Plutus V3), BLS12-381 builtins for Groth16 pairing verification
- **Circuits**: Circom 2 targeting BLS12-381, Poseidon commitments, Groth16 proof system
- **Off-chain**: Haskell (GHC 9.10+), cardano-node-clients for transaction construction
- **Point compression**: Rust FFI via blst crate
- **Proof generation**: snarkjs (to be replaced by native prover)

## Development Workflow

- Linear git history, conventional commits
- Specs precede implementation (SDD workflow)
- Small bisect-safe commits: every commit compiles
- Test at system boundaries: proof generation/verification round-trip, on-chain/off-chain interface

## Governance

This constitution supersedes all other practices. Privacy guarantees (Principle V) and proof soundness (Principle VI) cannot be weakened. The coalition model (Principle I) is the project's reason for existence.

**Version**: 4.0.0 | **Ratified**: 2026-04-15
