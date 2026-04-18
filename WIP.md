# WIP: Issue #10 — customer Ed25519 signature binds acceptor_pk + TxOutRef

## Status
Design agreed. Supersedes earlier nonce-Poseidon approach.
Issue #12 (Poseidon research) closed. Issue #13 filed for v2 privacy redesign (nullifier-based).

## Design summary

Circuit public inputs (post-PR):
  [d, commit_S_old, commit_S_new, user_id, issuer_Ax, issuer_Ay, pk_c_hi, pk_c_lo]
  — 8 inputs, IC = 9. acceptor_Ax/Ay removed (revert of #4 circuit addition).
  pk_c (customer Ed25519 pk, 32 bytes) split across two field elements.

Redeemer (Aiken):
  SpendRedeemer {
    d,
    commit_spent_new,
    issuer_ax, issuer_ay,
    pk_c_hi, pk_c_lo,           // match the proof's public inputs
    customer_pubkey: ByteArray, // 32 bytes Ed25519 compressed pk
    customer_signature: ByteArray,  // 64 bytes Ed25519 signature
    signed_data: ByteArray,     // canonical byte layout below
    proof: Groth16Proof,
  }

signed_data canonical byte layout (106 bytes total):
  txid        [32 bytes]   raw Cardano TxId
  ix          [ 2 bytes]   big-endian u16
  acceptor_ax [32 bytes]   big-endian 256-bit integer
  acceptor_ay [32 bytes]   big-endian 256-bit integer
  d           [ 8 bytes]   big-endian u64

Validator checks:
  1. VerifyEd25519Signature customer_pubkey signed_data customer_signature
  2. Parse signed_data -> (txid, ix, acceptor_ax, acceptor_ay, d).
  3. signed_data.d == redeemer.d (defence-in-depth).
  4. customer_pubkey matches (pk_c_hi || pk_c_lo) — bytes split 16+16 correspond to integers.
  5. TxOutRef(txid, ix) is in tx.inputs (list scan).
  6. Groth16.verify with public inputs incl. pk_c_hi, pk_c_lo.

Reificator trie check (reificator ∈ acceptor_pk) stays deferred to milestone 2.

## Plan
1. [x] Rescope #10; close #12; file #13
2. [ ] Docs: update cryptography.md, security.md, lifecycle.md, actors.md, constitution.md for customer-sig flow
3. [ ] Circuit: remove acceptor_Ax/Ay, add pk_c_hi/pk_c_lo as public inputs
4. [ ] JS: update generate_proof.js and generate_fixtures.js (generate Ed25519 keypair, split pk into hi/lo, build signed_data, sign it)
5. [ ] Recompile circuit + trusted setup + generate proof
6. [ ] Aiken types: SpendRedeemer with new fields; bump IC count comment
7. [ ] Aiken validator: Ed25519 verify + signed_data parse + checks
8. [ ] Haskell Types: SpendRedeemer shape with customer sig fields
9. [ ] Haskell Transaction: thread new args through spendVoucher
10. [ ] Haskell Serialize: spendRedeemer{ToData,ToCBOR} new signature
11. [ ] Regenerate VK and applied script (for fixtures)
12. [ ] Tests: Groth16Spec, E2ESpec updates (including Ed25519 signing in test fixtures)
13. [ ] Run all 7 CI checks locally
14. [ ] Clean commits (stgit if needed), push, open PR

## Notes
- Off-chain: customer's phone now holds sk_c (Ed25519) in addition to user_secret.
  Public key pk_c split hi/lo across two BLS12-381 field elements.
  Split convention (to pin down during implementation): first 16 bytes -> pk_c_hi as big-endian integer, last 16 bytes -> pk_c_lo.
- Plutus builtin VerifyEd25519Signature operates on raw bytes — signed_data must be
  in the exact canonical layout above (the customer's JS signing code must emit the
  same bytes the validator parses).
- Circuit binds pk_c as pass-through (no constraint); the validator uses pk_c for
  Ed25519 verification and also cross-checks it against customer_pubkey in redeemer.
