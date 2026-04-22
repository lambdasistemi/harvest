# WIP: Issue #23 — Card-based identity model + certificate anchoring

## Status
Design phase — Hydra-based architecture captured in constitution v6.0.0.
Blocked on Hydra research (see open questions below).

## What's done
- Constitution v6.0.0 with two-layer Hydra+L1 architecture
- All protocol docs updated for card model (actors, lifecycle, security, semantics)
- All architecture docs updated (cryptography — signed_data 74 bytes)
- All spec contracts updated (coalition-metadata-datum, voucher-datum, actions, signed-data-layout)
- Poseidon Merkle tree ruled out (on-chain Poseidon blows Plutus budget)
- SHA-256 MPF on Hydra + L1 reference input identified as viable alternative

## Key architecture (v6.0.0)

### Two layers, separated concerns
- **L1**: settlement, redemption, revert, shop/card registration, certificate root (reference input)
- **L2 (Hydra)**: topup transactions only, certificate MPF (SHA-256), near-zero fees

### Certificate anchoring (solves revocation catastrophe)
- Every topup = one Hydra transaction anchoring certificate_id in MPF
- certificate_id = Poseidon(user_id, cap) — exposed as circuit public input
- L1 validator checks SHA-256 MPF proof against certificate root (reference input)
- No Poseidon on-chain needed — Poseidon stays in-circuit, SHA-256 stays on-chain

### Key ceremony (shop-coalition separation)
- Shop generates its own Jubjub key pair, registers public key on L1
- Coalition manufactures cards with Ed25519 only
- Shop loads Jubjub private key onto cards (same key, all shop's cards)
- Coalition never sees Jubjub private key — cannot forge certificates

### Daily fan-out audit
- Hydra head processes topups all day
- End of day: changeset published to IPFS, shops audit and counter-sign
- Fan-out to L1 produces certificate root UTxO (reference input)
- Any shop can validate everything (all Jubjub public keys known from L1)

## Open research (blocks implementation)
1. Hydra snapshot finality — are signed snapshots irrevocable?
2. Hydra fan-out mechanics — how to produce certificate root UTxO on L1?
3. Can shops counter-sign as part of the fan-out protocol?
4. Hydra participant model — coalition alone, or shops participate?
5. IPFS changeset format and efficient validation

## What's NOT done
- Protocol docs update for Hydra layer (actors, lifecycle, security, semantics)
- Spec contracts update for certificate_id public input and certificate root
- On-chain validator changes
- Off-chain code changes
- Circuit changes (add certificate_id public input)
- Hydra integration (entirely new)
