# WIP: Issue #23 — Card-based identity model + certificate anchoring

## Status
Design phase — spec rewritten for MPFS batching (Hydra dropped).
Plan and tasks ready. Ready for review.

## What's done
- Constitution v7.0.0 with MPFS certificate batching (§III-A rewritten)
- All protocol docs updated for card model + MPFS batching (actors, lifecycle, security, semantics)
- All architecture docs updated (cryptography — signed_data 74 bytes, certificate_id index 8; on-chain — certificate root update)
- All spec contracts updated (certificate root, settlement MPF check)
- Poseidon Merkle tree ruled out (on-chain Poseidon blows Plutus budget)
- SHA-256 MPF on MPFS + L1 reference input identified as viable
- **Hydra research complete** — knowledge graph with 15 nodes merged
- **Hydra evaluated and rejected** — adds operational complexity (head lifecycle, contestation period, fan-out ceremony) without solving the trust problem better than coalition-signed batch receipts
- **Spec 004 rewritten** — MPFS certificate batching design
- **Plan written** — 6 implementation phases
- **Tasks written** — 22 tasks across circuit, on-chain, and off-chain

## Key Design Decisions

- Certificate MPF managed off-chain by MPFS (not on-chain, not Hydra)
- MPFS validates topup intents (card registered, Jubjub key matches)
- MPFS chains MPF inserts into batches, coalition signs batch receipts
- Certificate root updated on L1 periodically (reference input, zero contention)
- User's evidence = coalition-signed batch receipt (off-chain enforcement)
- Shop audit via IPFS changeset (same as before, simpler without Hydra)
- Revocation: MPFS reads updated coalition datum, rejects revoked cards immediately
- No Hydra node, no head lifecycle, no contestation period, no fan-out

## Why Not Hydra

1. Coalition is sole participant → "unanimous consensus" is just the coalition signing
2. Contestation protects against rollback, but enforcement of "you promised to include my topup" is off-chain regardless
3. MPFS already solves the batching/contention problem
4. Volume (hundreds of thousands of topups/day) requires batching anyway — Hydra's single-UTxO sequential processing would need MPFS-like batching on top
5. Simpler architecture: one less infrastructure component, no daily head lifecycle

## What's NOT done
- Review spec with user
- ~~Protocol docs update~~ ✓ Done
- On-chain validator changes (settlement MPF check, certificate root update)
- Off-chain code changes (MPFS certificate batching, reificator integration)
- Circuit changes (add certificate_id public input at index 8)
- IPFS changeset publication + verification tool
