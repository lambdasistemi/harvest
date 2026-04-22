# WIP: Issue #23 — Card-based identity model

## Status
Paused — blocked on Poseidon Merkle tree infrastructure.

## What's done
- Constitution updated to v5.0.0 with card-based identity model
- All protocol docs updated (actors, lifecycle, security, semantics)
- All architecture docs updated (cryptography — signed_data 74 bytes)
- All spec contracts updated (coalition-metadata-datum, voucher-datum, actions, signed-data-layout)
- Commit: b3a4c36

## Key design decisions (card model)
- Reificator is dumb commodity hardware — no keys, no secrets
- Both keys (Jubjub + Ed25519) loaded into reificator volatile RAM via NFC daily
- Jubjub key is per-shop (shared across all reificators of that shop)
- Ed25519 key is per-reificator (unique, for tx signing)
- Power-off = both keys vanish from RAM
- Security officer loads keys each morning, physical kill switch at close

## Unsolved: revocation catastrophe
Off-chain certificates (cap signed by Jubjub key) cannot be safely revoked:
- Leaked Jubjub key = unlimited certificate forgery
- In a coalition, forged certificates are a money printer against ALL other shops
- Revoking the key destroys all legitimate unspent balances (can't distinguish real from forged)
- This is an existential threat to the coalition model

### Required solution: on-chain certificate anchoring
- Batch Merkle root of certificates published on-chain (hourly/daily)
- After revocation, only anchored certificates are valid
- Requires Poseidon Merkle tree (not SHA-256) because membership must be verified inside ZK circuit
- Poseidon in-circuit: ~250 constraints/hash vs SHA-256: ~25,000
- Tree data published to IPFS (content-addressed), CID on-chain alongside root
- Data providers fetch from IPFS, serve Merkle paths, verify against on-chain root

### Missing infrastructure (blocks everything)
1. Poseidon hash in Aiken — does not exist
2. Poseidon Merkle tree in Aiken — does not exist
3. Poseidon Merkle tree in Haskell — does not exist
4. On-chain cost profiling — unknown, might kill the approach
5. IPFS/content-addressed publication layer for tree data
6. Contention management for anchor tree updates
7. Circuit extension for Merkle membership proof

## What's NOT done (blocked)
- On-chain validator changes (coalition datum restructure, acceptor binding)
- Off-chain code changes (Types.hs, HarvestFlow.hs)
- Circuit naming updates
- Devnet test updates
- Lean model updates

## Next project
Poseidon Merkle tree on Cardano — separate project, prerequisite for certificate anchoring.
