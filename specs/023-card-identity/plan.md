# Implementation Plan: Card-Based Identity Model + Certificate Anchoring

**Branch**: `023-card-identity` | **Date**: 2026-04-22 | **Spec**: [spec 004](../004-hydra-certificate-anchoring/spec.md)
**Input**: Constitution v7.0.0 §III-A, protocol docs, architecture docs

## Summary

Replace burned-in reificator keys with PIN-protected smart cards (Jubjub EdDSA + Ed25519). Anchor every topup in a SHA-256 MPF managed by MPFS. Update the certificate root on L1 periodically as a reference input. The settlement validator gains a certificate MPF membership check. The ZK circuit gains `certificate_id` at public input index 8.

## Technical Context

**Language/Version**: Aiken 1.1.x (on-chain), Haskell GHC 9.10 (off-chain), Circom 2 (circuits), Rust (FFI)
**Primary Dependencies**: MPFS (certificate batching + L1 settlements), aiken-lang/merkle-patricia-forestry (SHA-256 MPF), cardano-node-clients
**Storage**: On-chain UTxOs (L1 tries + certificate root), off-chain certificate MPF (MPFS), IPFS (changesets)
**Testing**: Aiken unit tests (validators), Haskell integration tests (off-chain), Circom witness tests (circuit)
**Target Platform**: Cardano mainnet (L1)
**Project Type**: Smart contract protocol (on-chain + off-chain + circuit)
**Constraints**: Plutus V3 budget limits, MPFS batching latency

## Constitution Check

| Gate | Status |
|------|--------|
| §III-A Certificate anchoring via MPFS | ✓ Plan follows MPFS batching model exactly |
| §V Proof soundness — certificate_id binding | ✓ Circuit exposes Poseidon(user_id, cap) at index 8, L1 validator checks MPF membership |
| §IV Privacy — cap stays hidden | ✓ Only Poseidon commitment on-chain, no Poseidon on-chain computation |
| §IX On-chain state — certificate root as reference input | ✓ Zero contention with settlement txs |
| §X Correct before optimized | ✓ Phased: circuit first, then validators, then MPFS integration |

## Project Structure

### Documentation (this feature)

```text
specs/023-card-identity/
├── plan.md              # This file
├── tasks.md             # Task breakdown
specs/004-hydra-certificate-anchoring/
├── spec.md              # Certificate anchoring spec (MPFS-based)
docs/protocol/           # Updated ✓
docs/architecture/       # Updated ✓
```

### Source Code (repository root)

```text
circuits/
├── voucher_spend.circom         # Add certificate_id public output (index 8)

onchain/
├── validators/
│   ├── settlement.ak            # Add certMpfProof check + certificate_id cross-check
│   └── certificate_root.ak     # NEW — certificate root update validator
├── lib/
│   └── mpf.ak                   # SHA-256 MPF verification (existing infra)

offchain/
├── src/
│   ├── Certificate/
│   │   ├── Batch.hs             # NEW — MPFS certificate batching logic
│   │   ├── Root.hs              # NEW — Certificate root update tx builder
│   │   └── Changeset.hs         # NEW — IPFS changeset publication + verification
│   └── Reificator.hs            # Update: submit topup intents to MPFS

tests/
├── onchain/
│   └── settlement_test.ak        # Update: certificate_id + MPF proof
├── offchain/
│   ├── Certificate/BatchSpec.hs   # NEW
│   └── Certificate/RootSpec.hs    # NEW
```

## Implementation Phases

### Phase 1: Circuit — Add certificate_id (index 8)

Smallest possible change. The circuit already computes `Poseidon(user_id, cap)` internally. Expose it as public input index 8. Update all fixtures. Total public inputs: 9.

**Changes**: `circuits/voucher_spend.circom`, fixture generator, all test fixtures
**Risk**: Low — additive change, no existing inputs affected

### Phase 2: On-chain — Settlement validator update

Add certificate MPF membership check to the existing settlement validator:
1. Read certificate root from reference input
2. Verify `MPF.member(certificate_id, certMpfProof, certRoot)`
3. Cross-check `certificate_id` matches circuit public input index 8

**Changes**: `onchain/validators/settlement.ak`, updated tests
**Risk**: Medium — modifying critical path validator
**Depends on**: Phase 1

### Phase 3: On-chain — Certificate root update validator

New validator for the L1 certificate root update transaction:
1. Input: current certificate root UTxO
2. Output: updated certificate root UTxO (new MPF root)
3. Signed by coalition

**Changes**: `onchain/validators/certificate_root.ak`, unit tests
**Risk**: Low — simple update validator

### Phase 4: Off-chain — MPFS certificate batching

Extend MPFS to handle topup intents:
- Validate intents (card registered, Jubjub key matches, Ed25519 sig valid)
- Chain MPF inserts into batches
- Sign batch receipts
- Return receipts to reificators

**Changes**: `offchain/src/Certificate/Batch.hs`, tests
**Risk**: Medium — extending MPFS with new intent type

### Phase 5: Off-chain — Certificate root update + IPFS changeset

- Build certificate root update transactions for L1
- Publish IPFS changeset JSON
- Changeset verification tool for shops

**Changes**: `offchain/src/Certificate/Root.hs`, `offchain/src/Certificate/Changeset.hs`, tests
**Risk**: Low — straightforward L1 tx + JSON publication
**Depends on**: Phase 3

### Phase 6: Off-chain — Reificator topup integration

Update the reificator to:
- Submit topup intents to MPFS after card signs certificate
- Wait for batch receipt
- Pass receipt to user's phone alongside cap certificate
- Queue intents if MPFS unreachable

**Changes**: `offchain/src/Reificator.hs`, integration tests
**Risk**: Medium — changes the topup flow end-to-end
**Depends on**: Phase 4

## Dependencies

```
Phase 1 (circuit) ── Phase 2 (settlement update) ── Phase 6 (reificator)
                                                         │
Phase 3 (cert root validator) ── Phase 5 (root update + IPFS)
                                                         │
Phase 4 (MPFS batching) ─────── Phase 6 (reificator) ───┘
```

Phases 1, 3, 4 can proceed in parallel. Phase 2 depends on 1. Phase 5 depends on 3. Phase 6 depends on 2 and 4.
