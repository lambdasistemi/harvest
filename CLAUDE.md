# harvest-001 Development Guidelines

Auto-generated from all feature plans. Last updated: 2026-04-18

## Active Technologies
- Aiken 1.1.x (Plutus V3) for on-chain tests; Haskell GHC 9.10 for off-chain tests and fixture generator; Node 20 (already in-tree) remains the phone-side signer and fixture producer. (002-e2e-tests)
- Fixture files under `circuits/build/fixtures/` and `offchain/test/fixtures/` (produced by the previous PR). No new persistent storage; generated Aiken source is a build artifact. (002-e2e-tests)

- Haskell (GHC 9.10+) for off-chain, Aiken (Plutus V3) for on-chain, Circom 2 for circuits, Rust for FFI + cardano-node-clients (tx construction), blst (BLS12-381 point compression), snarkjs (proof generation), circomlib (Poseidon, comparators) (001-groth16-voucher-spend)

## Project Structure

```text
src/
tests/
```

## Commands

cargo test [ONLY COMMANDS FOR ACTIVE TECHNOLOGIES][ONLY COMMANDS FOR ACTIVE TECHNOLOGIES] cargo clippy

## Code Style

Haskell (GHC 9.10+) for off-chain, Aiken (Plutus V3) for on-chain, Circom 2 for circuits, Rust for FFI: Follow standard conventions

## Recent Changes
- 002-e2e-tests: Added Aiken 1.1.x (Plutus V3) for on-chain tests; Haskell GHC 9.10 for off-chain tests and fixture generator; Node 20 (already in-tree) remains the phone-side signer and fixture producer.

- 001-groth16-voucher-spend: Added Haskell (GHC 9.10+) for off-chain, Aiken (Plutus V3) for on-chain, Circom 2 for circuits, Rust for FFI + cardano-node-clients (tx construction), blst (BLS12-381 point compression), snarkjs (proof generation), circomlib (Poseidon, comparators)

<!-- MANUAL ADDITIONS START -->
<!-- MANUAL ADDITIONS END -->
