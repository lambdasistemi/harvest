# Cardano Vouchers Constitution

## Vision

A loyalty coalition protocol on Cardano. Multiple businesses form a coalition. Each member issues voucher certificates to customers. Customers spend vouchers at any coalition member. One wallet, every loyalty program.

New members get instant foot traffic on day one — existing coalition users walk in and spend vouchers before the new member has issued a single certificate. Every redemption is a real sale. The coalition is the growth flywheel.

## Core Principles

### I. Coalition, Not Silos

The protocol eliminates per-business loyalty silos. Any coalition member issues vouchers. Any coalition member accepts them. Users earn at one place, spend at another. The coalition is the product — not the individual issuer. Joining the coalition means adding a verification key to the on-chain list. That is the only integration step.

### II. User Has No Wallet

The user has no Cardano wallet, no ADA, no signing keys. The user's phone holds certificates, private state (caps, running totals, randomness), and proving keys. When spending, the user generates a Groth16 proof on their phone and presents it to the supermarket. The supermarket submits the transaction using its own wallet. The user never interacts with the blockchain directly.

### III. Smart Contract as Trust Layer

Coalition members do not verify each other's certificates. The on-chain validator does. A fake certificate produces an invalid Groth16 proof. The transaction fails. Nobody loses anything. The smart contract is the only trust relationship — no APIs, no shared databases, no inter-member communication needed.

### IV. Privacy by Default

User balances and voucher caps are never revealed on-chain. All on-chain data is commitments (Poseidon hashes) or zero-knowledge proofs. Only the spend amount per transaction is public. The issuer who tops up a user's cap knows that cap (they signed it), but on-chain observers learn nothing about balances.

### V. Proof Soundness

No spend occurs without a valid Groth16 proof that the committed counter has not exceeded the hidden cap. A single Groth16 circuit handles everything: issuer signature verification, counter arithmetic, range check, and commitment binding. No second proof system (BBS+) is needed — the signature check is embedded in the circuit.

### VI. Monotonic State

Cap only grows (rewards). Spent only grows (redemptions). The invariant is always: spent <= cap. The gap is the user's available balance, known only to the user's phone. A new certificate always supersedes the old one with a higher cap. There is no revocation.

### VII. Earn and Spend in One Interaction

At checkout, the user can both spend existing vouchers and earn new ones in a single interaction. Spending is on-chain (Groth16 proof submitted by the supermarket). Earning is off-chain (supermarket signs a new certificate with a higher cap). The user walks away with an updated on-chain committed counter and a new certificate.

### VIII. On-Chain State: Nested Trie

The shared state is a Merkle Patricia Trie of tries: issuer -> user -> committed spend counter. A spend transaction updates one or more leaves, each with its own Groth16 proof. The trie root sits in a single coalition UTXO.

### IX. Correct Before Optimized

Start simple, prove correctness, then optimize. One UTXO per user before the trie. Single-issuer spends before multi-issuer. snarkjs before native prover. Every step end-to-end testable before the next.

### X. Nix-First

All dependencies, builds, and CI are Nix-managed. The flake produces all derivations. No global installs, no version drift.

## Technology Stack

- **On-chain**: Aiken (Plutus V3), BLS12-381 builtins for Groth16 pairing verification
- **Circuits**: Circom 2 targeting BLS12-381, Poseidon commitments, Groth16 proof system
- **Off-chain**: Haskell (GHC 9.10+), cardano-node-clients for transaction construction
- **Point compression**: Rust FFI via blst crate
- **Proof generation**: snarkjs (to be replaced by native prover)
- **State**: Merkle Patricia Trie (aiken-lang/merkle-patricia-forestry)

## Development Workflow

- Linear git history, conventional commits
- Specs precede implementation (SDD workflow)
- Small bisect-safe commits: every commit compiles
- Test at system boundaries: proof generation/verification round-trip, on-chain/off-chain interface

## Governance

This constitution supersedes all other practices. Privacy guarantees (Principle IV) and proof soundness (Principle V) cannot be weakened. The coalition model (Principle I) is the project's reason for existence.

**Version**: 3.0.0 | **Ratified**: 2026-04-14
