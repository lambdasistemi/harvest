# Quickstart: Voucher Spend

## Prerequisites

- Nix (with flakes enabled)
- A Cardano preprod wallet with test ADA (for the supermarket role)

## 1. Enter the dev shell

```bash
cd cardano-vouchers
nix develop
```

This provides: GHC, cabal, cargo, circom, node, aiken.

## 2. Compile the circuit

```bash
cd circuits
circom voucher_spend.circom --prime bls12381 --r1cs --wasm --sym -l node_modules -o build/
```

## 3. Run trusted setup

```bash
npx snarkjs powersoftau new bls12381 14 build/pot_0000.ptau
npx snarkjs powersoftau contribute build/pot_0000.ptau build/pot_0001.ptau --name="dev" -e="entropy"
npx snarkjs powersoftau prepare phase2 build/pot_0001.ptau build/pot_final.ptau
npx snarkjs groth16 setup build/voucher_spend.r1cs build/pot_final.ptau build/voucher_spend_0000.zkey
npx snarkjs zkey contribute build/voucher_spend_0000.zkey build/voucher_spend.zkey --name="dev" -e="entropy"
npx snarkjs zkey export verificationkey build/voucher_spend.zkey build/verification_key.json
```

## 4. Generate a test proof

```bash
node generate_proof.js
# Expected output: "Verification: VALID"
```

## 5. Build on-chain validators

```bash
cd ../onchain
aiken build
# voucher_spend should appear in plutus.json
```

## 6. Build off-chain tooling

```bash
just build-offchain
```

## 7. Run tests

```bash
just test-offchain
# Groth16Spec: 9/9 pass (JSON parse, compression, CBOR round-trip)
```

## 8. Submit a spend transaction (testnet)

*Requires cardano-node-clients integration — not yet implemented.*
