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

### III-A. Certificate Anchoring via MPFS Batching

The protocol anchors every topup in a SHA-256 Merkle Patricia Forestry (MPF) tree managed off-chain by MPFS. The certificate root is posted to L1 as a reference input — read by many settlement transactions, updated periodically, zero contention.

**Certificate anchoring**: every topup is an intent submitted to MPFS, which validates and batches it into the certificate MPF. At spend time on L1, the settlement redeemer includes a SHA-256 Merkle proof that the customer's `certificate_id` is in the committed root. The L1 validator checks this proof on-chain using existing MPF infrastructure. No Poseidon on-chain.

The `certificate_id` is `Poseidon(user_id, cap)` — computed inside the ZK circuit (which already verifies the issuer's Jubjub signature over this value) and exposed as a public input. The L1 validator cross-checks the circuit's `certificate_id` against the MPF membership proof. Cap stays hidden — only the Poseidon commitment is on-chain.

**Why MPFS batching**: topups are high-frequency, low-value. One L1 transaction per topup would be economically prohibitive. MPFS collects topup intents from reificators, chains MPF inserts into batches, and updates the certificate root on L1 periodically. The same MPFS infrastructure that handles L1 settlement contention also handles certificate batching — same interface, same trust model.

**Coalition-signed receipts**: when a batch is committed, the coalition signs `(batchNumber, previousRoot, newRoot, entries)`. Each reificator receives the coalition's signature as a receipt for the user. This receipt is the user's evidence that the coalition committed to including their topup. If the L1 root doesn't reflect a signed batch, the user has cryptographic proof of fraud — enforcement is off-chain (business/legal).

**Coalition censorship**: the coalition operates MPFS and could refuse to include legitimate topups. It cannot forge certificates (lacks shops' Jubjub keys), alter entries (card Ed25519 signatures would break), or invent shops (L1 registry is the source of truth). Censorship is detectable: the reificator sees whether its intent was included in the batch. Censorship is recoverable: the topup can be resubmitted.

**Shop audit**: periodically, the coalition publishes the changeset to IPFS:
1. Fetch the list of changes from IPFS (CID linked to the root update)
2. Every change is signed by a registered Ed25519 key (card identity) and references a registered Jubjub key (shop authorized the cap)
3. All shops can validate the entire changeset — every public key is known from L1
4. If any entry is unsigned, forged, or from an unregistered key → shop raises a dispute
5. A single honest shop catches any forgery

The coalition has zero room to fabricate certificates because it cannot produce any shop's Jubjub signature.

**Batching rhythm**: MPFS collects intents continuously. Batches are committed at a configurable interval (e.g. every few seconds, or every N intents). The certificate root on L1 is updated periodically (e.g. hourly or daily) — the frequency is an operational choice trading L1 fees against confirmation latency.

**Confirmation latency**: a topup is committed when the coalition signs the batch (sub-second). It becomes spendable on L1 after the next root update. The customer receives the coalition's batch receipt as proof of inclusion.

### IV. Privacy by Default

User balances and voucher caps are never revealed on-chain. All on-chain data is commitments (Poseidon hashes) or zero-knowledge proofs. Only the spend amount per transaction is public. The issuer who tops up a user's cap knows that cap (they signed it), but on-chain observers learn nothing about balances.

### V. Proof Soundness

No spend occurs without (a) a valid Groth16 proof that the committed counter has not exceeded the hidden cap, and (b) a customer Ed25519 signature binding the spend to a specific Cardano transaction and a specific accepting card.

Three bindings, split between the proof and the signature:

1. **Spend amount `d`** — Groth16 public input. Bound by the circuit constraint `S_new = S_old + d`. The customer's Ed25519 signature over `signed_data` cross-includes `d` for defence-in-depth.
2. **Acceptor card `acceptor_pk`** — the Ed25519 public key of the accepting card, included in `signed_data` (not a circuit public input). Bound by the customer's Ed25519 signature. The on-chain validator enforces that the transaction is signed by `acceptor_pk` and that `acceptor_pk` is a registered card in the coalition datum.
3. **Transaction identity** — the `TxOutRef` the reificator consumes is part of `signed_data` and bound by the Ed25519 signature. A TxOutRef is consumed at most once on-chain, so the signed redeemer can be submitted at most once. This replaces the earlier (abandoned) circuit-level nonce design.

The customer's Ed25519 public key `pk_c` is itself a pass-through public input to the circuit (split as `pk_c_hi`, `pk_c_lo`) — the validator cross-checks it against the redeemer's `customer_pubkey`, preventing an attacker from pairing a stolen proof with a different customer key.

Every card has two key pairs on a single secure element, serving different verification environments:

- **Jubjub EdDSA key** — signs cap certificates. Verified inside the ZK circuit (where `cap` is private and must stay hidden). Appears as `issuer_Ax`/`issuer_Ay` in the circuit's public inputs when the card acts as issuer.
- **Ed25519 key** — signs Cardano transactions, authenticates the card to customers. Verified by the Plutus validator via `VerifyEd25519Signature`. Appears as `acceptor_pk` in the customer's `signed_data` when the card acts as acceptor.

The two keys exist because two different verification environments (ZK circuit and Plutus validator) support different cryptography. The coalition datum registers both keys together as a pair under the same card identity — preventing mix-and-match attacks.

The **issuer** (card that signed the cap certificate) and the **acceptor** (card that submits the settlement) are per-transaction role labels, not separate actor types. Both are cards belonging to coalition shops. Earn at shop A's card, spend at shop B's card. The circuit verifies the issuer's Jubjub signature on the cap. The validator verifies the customer's Ed25519 signature binding the acceptor and checks the acceptor card is registered.

Circuit public inputs: `[d, commit_S_old, commit_S_new, user_id, issuer_Ax, issuer_Ay, pk_c_hi, pk_c_lo, certificate_id]`

`certificate_id` = `Poseidon(user_id, cap)` — computed inside the circuit (the circuit already verifies the issuer's Jubjub signature over this value) and exposed as a public input for the L1 validator to cross-check against the certificate root MPF proof.

`signed_data` layout (74 bytes): `txid (32) || ix (2) || acceptor_pk (32) || d (8)` — where `acceptor_pk` is the accepting card's Ed25519 public key.

A single Groth16 circuit handles issuer signature verification, counter arithmetic, range check, and commitment binding. The customer signature handles per-tx binding. A future extension supports multi-certificate spends (combining caps from multiple issuers in a single proof) — this is core to the value proposition, not an optimization.

### VI. Monotonic State

Cap only grows (rewards). Spent only grows (redemptions). The invariant is always: spent <= cap. The gap is the user's available balance, known only to the user's phone. A new certificate always supersedes the old one with a higher cap. There is no revocation.

### VII. Reification Model

Spending and redemption are decoupled in time and space.

#### Terminology

- **Reificator**: A commodity hardware device at a cashing point (shop). Has no keys of its own — it is a dumb terminal with a screen, network interface, and card slot. Stateless — all state is on-chain (pending trie). Screen is dormant between interactions but settlement runs continuously in the background while a card is inserted.
- **Card**: A PIN-protected smart card with a secure element. Holds two key pairs (Jubjub EdDSA + Ed25519) and is the shop's complete identity. Distributed by the coalition. The card activates the reificator when inserted; without it the reificator is inert.
- **Reification**: The act of exposing a settled spend to the physical world — the reificator's screen lights up and the casher sees the amount.
- **Settlement**: The reificator (with card inserted) submits the customer's ZK proof on-chain and waits for confirmation. Happens asynchronously, before the customer visits the shop.
- **Redemption**: The casher acknowledges the reified amount and applies the discount.
- **Topup**: The casher loads new reward points. The card signs a fresh cap certificate (Jubjub EdDSA) and sends it to the customer's phone via the reificator. **Requires the card to be inserted** — the reificator alone cannot issue certificates.

#### Card and Key Ceremony

The card is a PIN-protected smart card with a secure element. Two separate authorities control the two keys:

1. **Shop generates its Jubjub key pair** — the shop creates its own EdDSA-Poseidon keypair and registers the public key on L1. The private key never leaves the shop's control. The coalition never sees it.
2. **Coalition manufactures the card** — burns a unique Ed25519 key pair into the secure element (for Cardano transactions and customer authentication). The Ed25519 public key is registered in the coalition datum under the shop.
3. **Shop loads the Jubjub key onto the card** — the shop burns its Jubjub private key into the card's secure element. All cards belonging to the same shop carry the same Jubjub key (required because certificates are per-shop, not per-card). The shop handles this distribution — the coalition is not involved.
4. **Shop receives 2-3 cards per cashing point** — each with the same Jubjub key and a unique Ed25519 key. The shop inserts a card into the reificator to activate it. Spare cards are kept in a safe.
5. **PIN protection** — the secure element locks signing operations behind a PIN. N failed attempts lock the card permanently. A locked card is replaced from the safe and revoked on-chain.

**Separation of authority**: the coalition controls reificator identity (Ed25519 — it manufactured the card). The shop controls certificate signing (Jubjub — it generated and loaded the key). Neither can impersonate the other. The coalition cannot forge certificates because it never has the shop's Jubjub private key.

The reificator has no keys and no secrets. It is interchangeable commodity hardware. A shop's card works in any compatible reificator. Device breaks? Plug the card into a new one. No re-registration needed.

#### Two Key Pairs, One Card

Each card holds two key pairs on a single secure element:

1. **Jubjub EdDSA key** — signs cap certificates (`issuer_pk` in the circuit). Verified inside ZK proofs. Required because `cap` is private and must remain hidden — only an in-circuit verifier can check the signature without revealing it.
2. **Ed25519 key** — signs Cardano transactions, authenticates the card to customers, signs reification certificates. Verified by the Plutus validator (`VerifyEd25519Signature`) and by customer phones.

Both keys are registered together in the coalition datum as a pair under the same card identity. The two keys exist because two verification environments (ZK circuit and Plutus validator) support different cryptography.

#### Spend Lifecycle

A spend has three states:

```
committed → redeemed  (card signs via reificator — device confirms physical redemption)
         → reverted   (shop signs — business authority reverses the settlement)
```

The card (via reificator) can redeem but cannot revert. The shop can revert but cannot redeem. Separation of concerns — the physical device handles the happy path, the business authority handles recovery.

#### Flow

1. **At home**: Customer chooses a spending shop and contacts its reificator. The reificator (with card inserted) authenticates via the card's Ed25519 key. Customer verifies the card is registered in the coalition datum. Customer reads the certificate root (reference input on L1) and obtains a SHA-256 Merkle proof that their `certificate_id` is anchored. Customer generates a ZK proof binding the amount `d`, the issuer card's Jubjub key, and exposing `certificate_id` as a public input. Customer signs `signed_data` binding the accepting card's Ed25519 public key, a TxOutRef, and `d`.
2. **Settlement**: Reificator submits the proof on L1. The validator checks: (a) the Groth16 proof is valid, (b) the customer's Ed25519 signature over `signed_data` is valid, (c) `acceptor_pk` is a registered card, (d) the transaction is signed by `acceptor_pk`, (e) the `certificate_id` from the proof's public inputs has a valid SHA-256 Merkle proof against the certificate root (reference input). The spend counter updates and a pending entry is created in the pending trie (committed state).
3. **Certificate**: Card signs a reification certificate (Ed25519, with nonce) via the reificator, returned to the phone.
4. **At the shop**: Customer reaches the cashing point. Reificator screen is dormant.
5. **Reification**: Customer presents certificate. Reificator verifies the card's signature, queries data provider for Merkle membership proof of the nonce in the pending trie. If valid — switches to present state, displays the spent amount.
6. **Redemption**: Casher acknowledges, applies the discount. Reificator submits redemption request (signed by card) — pending entry removed from trie (redeemed).
7. **Topup**: Casher sets new reward amount. Card signs a fresh cap certificate (Jubjub EdDSA). The reificator submits a topup intent to MPFS, which validates and anchors the `certificate_id = Poseidon(user_id, cap)` in the certificate MPF batch. The signed certificate is sent to the phone. The coalition's batch receipt is returned as proof of inclusion. **Requires the card to be inserted.**
8. **Dormant**: Reificator screen goes dormant. Background settlement continues (only while card is inserted).

#### Device Loss / Theft

**Reificator stolen (card not inserted):** Zero risk. The reificator holds no keys and no secrets. It is inert without a card. Replace the hardware.

**Reificator stolen (card inserted):** The thief has a functioning device with signing capability. The card is PIN-protected — N failed attempts lock it permanently. Recovery:

1. Shop revokes the card's public keys from the coalition datum on-chain.
2. Shop walks the card's subtree in the pending trie.
3. Shop signs reverts for all committed-but-unredeemed entries — spend counters are rolled back, pending entries removed.
4. Affected customers' on-chain state is restored. They can re-spend through a different card.
5. Shop inserts a spare card into a new (or the same) reificator. No re-registration needed for the reificator — only the card identity matters.

**Card lost or locked:** Replace from the safe. Revoke the old card on-chain. Insert the spare into any reificator.

#### Security Properties

- **No double-spend**: Settlement happens before the customer visits the shop. On-chain confirmation has minutes/hours, not seconds.
- **No amount tampering**: The ZK proof binds the spend amount `d` as a public input. No party can alter it without invalidating the proof. The customer's Ed25519 signature cross-binds `d` in `signed_data`.
- **No acceptor misdirection**: The customer's Ed25519 signature binds `acceptor_pk` (the accepting card's Ed25519 public key) in `signed_data`. The on-chain validator enforces that the transaction is signed by `acceptor_pk` and that `acceptor_pk` is a registered card. A proof intended for card B cannot be submitted by card A.
- **No certificate replay**: Reification certificates carry nonces. Each nonce maps to a pending trie entry on-chain, consumed on redemption.
- **Card-bound**: Reification certificates are signed by the card's Ed25519 key and redeemable only at a reificator with that card inserted.
- **No certificate forgery**: Cap certificates require the card's Jubjub EdDSA key (inside the secure element, behind a PIN). A stolen reificator without the card cannot produce certificates — it has no signing keys at all. Even with a stolen card, forged certificates must be anchored via MPFS (requires a registered Ed25519 key) and survive shop audit.
- **Anchoring revocation**: after key compromise, the shop revokes the card on L1. MPFS rejects new topup intents from the revoked Ed25519 key. The damage window is limited to: time between compromise and revocation. Certificates anchored before revocation are cryptographically legitimate (signed by the shop's Jubjub key); the question of whether they were authorized is a business matter, not a protocol one.
- **Recoverable**: Stolen or malfunctioning devices cannot prevent recovery. The shop revokes the card on-chain and reverts pending entries with the master key. Spare cards from the safe restore service immediately.
- **Threat model**: The protocol protects against device failure (malfunction, theft, vandalism) and coalition misbehavior (forgery, fabrication). It does not protect against malicious shops — the shop is assumed cooperative. Theft of an active reificator with card inserted is mitigated by PIN protection, on-chain revocation, and MPFS validation (revoked cards rejected immediately).

#### State

| Location | What it holds |
|----------|--------------|
| **L1 — spend trie** | issuer_card → user → commit(spent) |
| **L1 — card trie** | shop → card_pk pair (jubjub_pk, ed25519_pk) |
| **L1 — pending trie** | card_ed25519_pk → nonce → {user_id, amount} |
| **L1 — certificate root** | SHA-256 MPF root hash (reference input, updated periodically by coalition) |
| **Off-chain — certificate MPF** | (issuer_jubjub_pk, user_id) → certificate_id. Full MPF managed by MPFS, updated per batch |
| **User's phone** | User secret, Ed25519 keypair (`sk_c`, `pk_c`), spend randomness, cap certificates (signed by card's Jubjub key), reification certificates (signed by card's Ed25519 key), coalition batch receipts |
| **Card (secure element)** | Jubjub EdDSA private key (per-shop, loaded by shop) + Ed25519 keypair (per-card, burned by coalition), PIN-protected |
| **Reificator** | Cardano payment key + UTXO for fees. No identity keys — all signing delegated to the inserted card. Stateless commodity hardware. Submits topup intents to MPFS. |

### VIII. Economic Model

The costs flow downward from coalition to shop:

| Actor | Responsibility | Cost |
|-------|---------------|------|
| **Coalition** | Runs MPFS (certificate batching + L1 settlements), publishes trie roots off-chain, manufactures cards (Ed25519 only) | MPFS infrastructure + root publication + card production |
| **Data providers** | Serve Merkle proofs to reificators (untrusted, verifiable against on-chain root) — both spend trie and certificate tree | Paid per query by reificators |
| **Reificators** | Query providers for proofs, build and submit L1 transactions (settlement/redeem/revert), submit topup intents to MPFS | Paid from the device's UTXO (L1 fees only — topup intents are free) |
| **Shops** | Fund their reificators' UTXOs with ADA, generate and distribute Jubjub keys to cards, audit certificate changesets | Cost of doing business (like card processing fees) |

The shop refills the reificator's UTXO. Each card's Ed25519 public key derives a Cardano address visible in the coalition datum — the shop knows exactly which address to top up. The reificator spends from it for L1 transaction fees and data provider queries. Topup intents go through MPFS at zero cost.

Data providers serve two trees: the spend trie (L1) and the certificate tree (updated by MPFS batching). Both are SHA-256 MPF, same infrastructure, same trust model. Providers compete on price and availability.

Fee deduction from loyalty points (converting points to ADA on-chain) is a future optimization, not a day-one requirement.

### IX. On-Chain State

**L1 production form.** Two UTxOs:

1. **Trie root UTxO** (consumed by settlement/redeem/revert): holds the current root hash of three Merkle Patricia Tries:

| Trie | Structure | Purpose |
|------|-----------|---------|
| **Spend trie** | issuer_card → user → commit(spent) | Tracks cumulative spending per user per issuer card |
| **Card trie** | shop → (jubjub_pk, ed25519_pk) | Registered cards, managed by coalition. Each entry is a key pair under a shop identity |
| **Pending trie** | card_ed25519_pk → nonce → {user_id, amount} | Committed-but-unredeemed spends |

2. **Certificate root UTxO** (reference input only, never consumed by spends): holds the SHA-256 MPF root of the certificate tree, updated periodically by the coalition via MPFS. Zero contention with settlement transactions.

The full trie data lives off-chain, published by the coalition. Untrusted data providers serve Merkle proofs verified against the on-chain root. The on-chain validator checks the Merkle proof in each transaction's redeemer and outputs a new root UTXO with the updated hash.

**Off-chain (MPFS).** The full certificate MPF is managed by MPFS:

| Structure | Purpose |
|-----------|---------|
| (issuer_jubjub_pk, user_id) → certificate_id | Maps each (shop, customer) pair to the current `certificate_id = Poseidon(user_id, cap)`. Updated per topup batch. |

MPFS periodically updates the certificate root UTxO on L1. The changeset is published to IPFS for shop audit.

**L1 prototype form (issue #9).** The prototype models the same semantics over explicit sets, without MPF/MPFS:

| Artefact | Structure | Replaces |
|----------|-----------|----------|
| **Coalition-metadata UTxO** (reference input) | `CoalitionDatum { issuer_pk, cards : Map shop_pk [(jubjub_pk, ed25519_pk)] }` | Card trie + coalition registry |
| **Per-customer script UTxO** (one per customer) | `VoucherDatum { user_id, commit_spent, card_ed25519_pk }` | Spend trie (one entry per UTxO) + Pending trie (present = committed, absent = redeemed/reverted) |
| **Certificate root UTxO** (reference input) | `CertRootDatum { mpf_root }` | Certificate MPF root from MPFS batching |

Every security invariant of §V–§VII holds over the prototype form at N ∈ {1, 2, 3} with the same check structure (enforced in-validator rather than as a Merkle proof). The prototype form is wire-incompatible with the production form; migration from one to the other is tracked as a refinement obligation under issues #5 (MPF on-chain) and #8 (MPFS mediation). The prototype is correct and complete at small N; it is **not** operationally usable at scale — that is by design (Principle X).

Every spend involves two on-chain (L1) transactions:

1. **Settlement tx**: updates the spend trie (counter goes up) and inserts into the pending trie. Submitted by the reificator (card signs the transaction via Ed25519), includes the Groth16 proof. The validator checks that `acceptor_pk` from `signed_data` is a registered card, that the transaction is signed by that card, and that the `certificate_id` from the proof's public inputs has a valid membership proof in the certificate root (reference input).
2. **Redemption tx**: removes the entry from the pending trie. Submitted by the reificator after physical redemption, signed by the card's Ed25519 key. No ZK proof needed.

A revert is a single transaction: removes from the pending trie and rolls back the spend trie. Signed by the shop's master key.

Topup is an intent submitted to MPFS — the card signs a new cap certificate (Jubjub EdDSA) and the reificator submits a topup intent anchoring the `certificate_id` in the certificate MPF batch. Zero cost for the reificator. The certificate becomes spendable on L1 after the next certificate root update.

### X. Correct Before Optimized

Start simple, prove correctness, then optimize. One UTXO per user before the trie. Single-issuer spends before multi-issuer. snarkjs before native prover. Every step end-to-end testable before the next.

### XI. Nix-First

All dependencies, builds, and CI are Nix-managed. The flake produces all derivations. No global installs, no version drift.

## Technology Stack

- **L1 on-chain**: Aiken (Plutus V3), BLS12-381 builtins for Groth16 pairing verification, SHA-256 MPF for certificate root verification
- **Certificate batching**: MPFS (same infrastructure as L1 settlement contention, extended for topup intents)
- **Circuits**: Circom 2 targeting BLS12-381, Poseidon commitments (using `poseidon-bls12381-circom`), EdDSA-Poseidon on Jubjub, Groth16 proof system
- **Off-chain**: Haskell (GHC 9.8.4), cardano-node-clients for transaction construction
- **Point compression**: Rust FFI via blst crate
- **Proof generation**: snarkjs (to be replaced by native Rust prover, see issue #2)
- **State (L1)**: Merkle Patricia Trie (aiken-lang/merkle-patricia-forestry) — spend/card/pending tries + certificate root
- **State (off-chain)**: Certificate MPF managed by MPFS
- **Publication**: IPFS for periodic changeset publication (shop audit)

### Open Research (blocks production deployment)

1. **IPFS changeset format** — what exactly is published, and how do shops efficiently validate it?
2. **Certificate root as reference input** — verify that CIP-31 reference inputs work across concurrent settlement transactions without contention
3. **MPFS certificate batching throughput** — validate that MPFS can handle hundreds of thousands of topup intents per day with acceptable batch latency
4. **Coalition batch receipt format** — define the exact signed payload that serves as the user's proof of inclusion

## Development Workflow

- Linear git history, conventional commits
- Specs precede implementation (SDD workflow)
- Small bisect-safe commits: every commit compiles
- Test at system boundaries: proof generation/verification round-trip, on-chain/off-chain interface

## Governance

This constitution supersedes all other practices. Privacy guarantees (Principle IV) and proof soundness (Principle V) cannot be weakened. The coalition model (Principle I) is the project's reason for existence.

**Version**: 7.0.0 | **Ratified**: 2026-04-16 | **Last Amended**: 2026-04-22 (§III-A rewritten: Hydra dropped in favor of MPFS certificate batching — simpler, same security properties, handles high-volume topups natively)
