# WIP: Issue #4 — Add acceptor_pk as circuit public input

## Status
Design refined — using "acceptor" (not "shop") to disambiguate from "issuer".
Docs updated for terminology. Ready to implement.

Follow-up issue #5 (to be created): add nonce (TxOutRef) binding for replay protection.

## Plan (this PR — #4 only)
1. [ ] Update `circuits/voucher_spend.circom` — add `acceptor_Ax`, `acceptor_Ay` as public inputs
2. [ ] Update `circuits/lib/jubjub_eddsa.js` — include acceptor_pk pass-through in test signing
3. [ ] Recompile circuit, run trusted setup, regenerate proof
4. [ ] Update `onchain/lib/voucher/types.ak` — add acceptor_ax, acceptor_ay to SpendRedeemer
5. [ ] Update `onchain/validators/voucher_spend.ak` — add to public inputs list, update IC count (7 → 9)
6. [ ] Update `offchain/src/Harvest/Types.hs` — add acceptor fields to SpendRedeemer
7. [ ] Update `offchain/src/Harvest/Transaction.hs` — pass acceptor_pk through
8. [ ] Update `offchain/src/Cardano/Groth16/Serialize.hs` — update spendRedeemerToData
9. [ ] Regenerate VK, re-apply blueprint, update test fixtures
10. [ ] Update tests (Groth16Spec, E2ESpec, circuit tests)
11. [ ] Run all 7 CI checks locally
12. [ ] Push, PR, merge

## Notes
- "acceptor" replaces "shop" in role-specific (per-tx) contexts; generic "Shop" entity stays.
- acceptor_pk is pass-through in the circuit (no constraints) — the on-chain validator checks reificator trie.
- Validator trie check deferred to milestone 2 (three-trie model).
- Public inputs after #4: [d, commit_S_old, commit_S_new, user_id, issuer_Ax, issuer_Ay, acceptor_Ax, acceptor_Ay]
- IC count goes from 7 to 9.
- Follow-up #5 will add a 9th public input `nonce` bound to a TxOutRef consumed in the submitting tx.

## Next milestone (after #4 + #10)
Security model review: formalize issuer, customer, reificator as actors subject to the validator.
Make the model right and fair — each actor's capabilities bounded by on-chain checks.
Likely artifacts: threat tables per actor, Lean formalization of invariants, validator spec.

## Docs updates already applied (design phase)
- docs/architecture/cryptography.md: circuit public inputs table renamed shop_* → acceptor_*
- docs/protocol/lifecycle.md: "spending shop" → "acceptor" with clarifying note
- docs/protocol/security.md: attack analysis + privacy table updated
- docs/protocol/actors.md: added "Role terminology" section explaining issuer vs acceptor
