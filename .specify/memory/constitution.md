# Harvest Constitution

## Vision

A loyalty coalition protocol on Cardano. Multiple businesses form a coalition. Each member issues voucher certificates to customers. Customers spend vouchers at any coalition member. One wallet, every loyalty program.

New members get instant foot traffic on day one — existing coalition users walk in and spend vouchers before the new member has issued a single certificate. Every redemption is a real sale. The coalition is the growth flywheel.

## Core Principles

### I. Coalition, Not Silos

The protocol eliminates per-business loyalty silos. Any coalition member issues vouchers. Any coalition member accepts them. Users earn at one place, spend at another. The coalition is the product — not the individual issuer. Joining the coalition means adding a verification key to the on-chain list. That is the only integration step.

### II. User Has No Wallet

The user has no Cardano wallet, no ADA, no signing keys. The user's phone holds certificates, private state (randomness, proving keys), and communicates with reificators. The user never interacts with the blockchain directly.

### III. Smart Contract as Trust Layer

Coalition members do not verify each other's certificates. The on-chain validator does. A fake certificate produces an invalid Groth16 proof. The transaction fails. Nobody loses anything. The smart contract is the only trust relationship — no APIs, no shared databases, no inter-member communication needed.

### IV. Privacy by Default

User balances and voucher caps are never revealed on-chain. All on-chain data is commitments (Poseidon hashes) or zero-knowledge proofs. Only the spend amount per transaction is public. The issuer who tops up a user's cap knows that cap (they signed it), but on-chain observers learn nothing about balances.

### V. Proof Soundness

No spend occurs without (a) a valid Groth16 proof that the committed counter has not exceeded the hidden cap, and (b) a customer Ed25519 signature binding the spend to a specific Cardano transaction.

Three bindings, split between the proof and the signature:

1. **Spend amount `d`** — Groth16 public input. Bound by the circuit constraint `S_new = S_old + d`. The customer's Ed25519 signature over `signed_data` cross-includes `d` for defence-in-depth.
2. **Acceptor `acceptor_pk`** — part of `signed_data` (not a circuit public input). Bound by the customer's Ed25519 signature. The on-chain validator enforces that the submitting reificator belongs to `signed_data.acceptor_pk` (reificator trie).
3. **Transaction identity** — the `TxOutRef` the reificator consumes is part of `signed_data` and bound by the Ed25519 signature. A TxOutRef is consumed at most once on-chain, so the signed redeemer can be submitted at most once. This replaces the earlier (abandoned) circuit-level nonce design.

The customer's Ed25519 public key `pk_c` is itself a pass-through public input to the circuit (split as `pk_c_hi`, `pk_c_lo`) — the validator cross-checks it against the redeemer's `customer_pubkey`, preventing an attacker from pairing a stolen proof with a different customer key.

The issuer (shop that signed the cap certificate) and the acceptor (shop where the spend happens) are role labels on coalition members, not separate actor types. Both are shops. Earn at shop A, spend at shop B. The circuit verifies the issuer's signature on the cap. The validator verifies the customer's Ed25519 signature and that the reificator belongs to the chosen acceptor.

Circuit public inputs: `[d, commit_S_old, commit_S_new, user_id, issuer_Ax, issuer_Ay, pk_c_hi, pk_c_lo]`

A single Groth16 circuit handles issuer signature verification, counter arithmetic, range check, and commitment binding. The customer signature handles per-tx binding. A future extension supports multi-certificate spends (combining caps from multiple issuers in a single proof) — this is core to the value proposition, not an optimization.

### VI. Monotonic State

Cap only grows (rewards). Spent only grows (redemptions). The invariant is always: spent <= cap. The gap is the user's available balance, known only to the user's phone. A new certificate always supersedes the old one with a higher cap. There is no revocation.

### VII. Reification Model

Spending and redemption are decoupled in time and space.

#### Terminology

- **Reificator**: A device at a cashing point (shop). Has a signing key, settles proofs on-chain, signs certificates. Stateless — all state is on-chain (pending trie). Screen is dormant between interactions but settlement runs continuously in the background.
- **Reification**: The act of exposing a settled spend to the physical world — the reificator's screen lights up and the casher sees the amount.
- **Settlement**: The reificator submits the customer's ZK proof on-chain and waits for confirmation. Happens asynchronously, before the customer visits the shop.
- **Redemption**: The casher acknowledges the reified amount and applies the discount.
- **Topup**: The casher loads new reward points. The reificator signs a fresh cap certificate and sends it to the customer's phone.

#### Key Ceremony

The reificator is a secure hardware device. Two keys are burned in at different times by different authorities:

1. **Reificator key** — burned in at manufacturing by the coalition/distributor. This is the device's own identity. At ceremony time, the reificator's public key is added to the on-chain reificator trie.
2. **Shop key** — burned in when the device is installed at a shop. This is the shop's authority for signing cap certificates (issuer_pk in the circuit).

Both keys live in secure hardware. Neither can be extracted. If the device is stolen, the shop's master key (held separately, not on the device) can sign reverts and revoke the reificator from the on-chain trie.

#### Two Signing Roles

The reificator signs in two capacities:

1. **As the shop** (issuer): signs cap certificates (`issuer_pk` in the circuit). These are verified inside the ZK proof on-chain.
2. **As itself** (reificator identity): signs reification certificates, bound to its own identity and a nonce. These are verified at redemption by checking the nonce against the pending trie.

#### Spend Lifecycle

A spend has three states:

```
committed → redeemed  (reificator signs — device confirms physical redemption)
         → reverted   (shop signs — business authority reverses the settlement)
```

The reificator can redeem but cannot revert. The shop can revert but cannot redeem. Separation of concerns — the physical device handles the happy path, the business authority handles recovery.

#### Flow

1. **At home**: Customer chooses a spending shop and generates a ZK proof binding both the amount `d` and the shop's public key. Contacts the shop's reificator remotely with the proof.
2. **Settlement**: Reificator submits the proof on-chain. The spend counter updates and a pending entry is created in the pending trie (committed state).
3. **Certificate**: Reificator returns a signed reification certificate (with nonce) to the phone.
4. **At the shop**: Customer reaches the cashing point. Reificator screen is dormant.
5. **Reification**: Customer presents certificate. Reificator verifies its own signature, queries data provider for Merkle membership proof of the nonce in the pending trie. If valid — switches to present state, displays the spent amount.
6. **Redemption**: Casher acknowledges, applies the discount. Reificator submits redemption request — pending entry removed from trie (redeemed).
7. **Topup**: Casher sets new reward amount. Reificator signs a fresh cap certificate for the shop, sends to phone.
8. **Dormant**: Reificator screen goes dormant. Background settlement continues.

#### Device Loss / Theft

If a reificator is stolen or destroyed:

1. Shop removes the reificator's public key from the on-chain reificator trie (revocation).
2. Shop walks the stolen reificator's subtree in the pending trie.
3. Shop signs reverts for all committed-but-unredeemed entries — spend counters are rolled back, pending entries removed.
4. Affected customers' on-chain state is restored. They can re-spend through a different reificator.

#### Security Properties

- **No double-spend**: Settlement happens before the customer visits the shop. On-chain confirmation has minutes/hours, not seconds.
- **No amount tampering**: The ZK proof binds the spend amount `d` as a public input. No party can alter it without invalidating the proof.
- **No shop misdirection**: The ZK proof binds the spending shop's public key. The on-chain validator checks that the submitting reificator is registered under that shop in the reificator trie. A proof generated for shop B cannot be submitted by shop A's reificator.
- **No certificate replay**: Reification certificates carry nonces. Each nonce maps to a pending trie entry on-chain, consumed on redemption.
- **Reificator-bound**: Reification certificates are redeemable only at the reificator that issued them.
- **Recoverable**: Stolen, destroyed, or malfunctioning devices cannot prevent recovery. The shop's master key can revert all pending entries. The pending trie provides on-chain evidence for the shop to act on.
- **Threat model**: The protocol protects against device failure (malfunction, theft, vandalism), not against malicious shops. The shop is assumed cooperative — it has every incentive to serve its customers. Collusion between shop and reificator is outside the threat model.

#### State

| Location | What it holds |
|----------|--------------|
| **On-chain — spend trie** | issuer → user → commit(spent) |
| **On-chain — reificator trie** | shop → reificator_pk (authorized devices) |
| **On-chain — pending trie** | reificator_pk → nonce → {user_id, amount} |
| **User's phone** | User secret, spend randomness, cap certificates (signed by shop key), reification certificates (signed by reificator key) |
| **Reificator** | Reificator key (burned by distributor), shop key (burned by shop), Cardano payment key + UTXO for fees. Stateless — no local data beyond keys. |

### VIII. Economic Model

The costs flow downward from coalition to shop:

| Actor | Responsibility | Cost |
|-------|---------------|------|
| **Coalition** | Publishes trie roots off-chain | Minimal — just root publication |
| **Data providers** | Serve Merkle proofs to reificators (untrusted, verifiable against on-chain root) | Paid per query by reificators |
| **Reificators** | Query providers for proofs, build and submit transactions | Paid from the device's UTXO |
| **Shops** | Fund their reificators' UTXOs with ADA | Cost of doing business (like card processing fees) |

The shop refills the reificator's UTXO. The reificator spends from it for transaction fees and data provider queries. The busier the reificator, the more the shop pays. Data providers compete on price and availability — the market sets the cost.

Fee deduction from loyalty points (converting points to ADA on-chain) is a future optimization, not a day-one requirement.

### IX. On-Chain State: Three Tries

A single UTXO holds the current root hash of three Merkle Patricia Tries:

| Trie | Structure | Purpose |
|------|-----------|---------|
| **Spend trie** | issuer → user → commit(spent) | Tracks cumulative spending per user per issuer |
| **Reificator trie** | shop → reificator_pk | Authorized devices, managed by shops |
| **Pending trie** | reificator_pk → nonce → {user_id, amount} | Committed-but-unredeemed spends |

The full trie data lives off-chain, published by the coalition. Untrusted data providers serve Merkle proofs verified against the on-chain root. The on-chain validator checks the Merkle proof in each transaction's redeemer and outputs a new root UTXO with the updated hash.

Every spend involves two on-chain transactions:

1. **Settlement tx**: updates the spend trie (counter goes up) and inserts into the pending trie. Submitted by the reificator, includes the Groth16 proof.
2. **Redemption tx**: removes the entry from the pending trie. Submitted by the reificator after physical redemption, signed by the reificator key. No ZK proof needed.

A revert is a single transaction: removes from the pending trie and rolls back the spend trie. Signed by the shop's master key.

Topup is off-chain only — the shop signs a new cap certificate, no transaction. This is deliberate: topups are high-frequency, low-value (a few euros of rewards). Spends are low-frequency, high-value (30-50+ euros) — two transactions are economically negligible.

### X. Correct Before Optimized

Start simple, prove correctness, then optimize. One UTXO per user before the trie. Single-issuer spends before multi-issuer. snarkjs before native prover. Every step end-to-end testable before the next.

### XI. Nix-First

All dependencies, builds, and CI are Nix-managed. The flake produces all derivations. No global installs, no version drift.

## Technology Stack

- **On-chain**: Aiken (Plutus V3), BLS12-381 builtins for Groth16 pairing verification
- **Circuits**: Circom 2 targeting BLS12-381, Poseidon commitments, EdDSA-Poseidon on Jubjub, Groth16 proof system
- **Off-chain**: Haskell (GHC 9.8.4), cardano-node-clients for transaction construction
- **Point compression**: Rust FFI via blst crate
- **Proof generation**: snarkjs (to be replaced by native Rust prover, see issue #2)
- **State**: Merkle Patricia Trie (aiken-lang/merkle-patricia-forestry)

## Development Workflow

- Linear git history, conventional commits
- Specs precede implementation (SDD workflow)
- Small bisect-safe commits: every commit compiles
- Test at system boundaries: proof generation/verification round-trip, on-chain/off-chain interface

## Governance

This constitution supersedes all other practices. Privacy guarantees (Principle IV) and proof soundness (Principle V) cannot be weakened. The coalition model (Principle I) is the project's reason for existence.

**Version**: 4.0.0 | **Ratified**: 2026-04-16
