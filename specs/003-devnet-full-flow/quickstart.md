# Quickstart: Running the Devnet Full-Flow E2E Tests

This document describes how to run the #9 test suite locally. It
extends `specs/002-e2e-tests/quickstart.md` — every instruction there
still applies; this file adds only what is new for the full-flow
scope.

## Run the full suite

```bash
just ci
```

The `checks.unit-tests` nix derivation now runs four additional
hspec modules alongside the #15 single-spend baseline:

- `DevnetFullFlowSpec`    — Story 1 (P1).
- `DevnetRedeemSpec`      — Story 2 (P2).
- `DevnetRevertSpec`      — Story 3 (P3).
- `DevnetRevocationSpec`  — Story 4 (P3).

Each module spins up its own `withDevnet` bracket. On a workstation
the incremental cost is ~4–5 minutes above the existing baseline.

## Run only one story

Each spec file owns its bracket, so individual stories can be
exercised in isolation (SC-003):

```bash
cabal test harvest-test-suite --test-options="--match DevnetFullFlowSpec"
cabal test harvest-test-suite --test-options="--match DevnetRedeemSpec"
cabal test harvest-test-suite --test-options="--match DevnetRevertSpec"
cabal test harvest-test-suite --test-options="--match DevnetRevocationSpec"
```

Running only P1 against a freshly-spun devnet is the canonical MVP
smoke test.

## Run the single-spend baseline from #15

```bash
cabal test harvest-test-suite --test-options="--match DevnetSpendSpec"
```

The #15 suite was migrated onto the #9 on-chain shape as part of
T021b: every `DevnetSpendSpec` scenario now bootstraps a single-member
coalition (one shop, one reificator) and threads the coalition
reference input through its settlement tx. The #15 assertions are
unchanged; only the tx shape is. There is **one** `voucher_spend`
validator with **one** code path — no "legacy no-ref" branch.

## Regenerate fixtures (after circuit or signer change)

Same as the #15 / #2 quickstarts, extended with the new per-customer
entries:

```bash
cd circuits
node generate_fixtures.js            # now emits c1, c2, cert-1, cert-2
cp build/fixtures/*.json ../offchain/test/fixtures/
cp build/fixtures/applied-*.hex ../offchain/test/fixtures/
cd ..
just ci
```

The #9 test modules read the extended fixture tree at runtime. No
Haskell generator to regenerate.

## Add a new scenario

The mutation framework from #15 carries over. For negative scenarios
under the full-flow suite:

1. Open the relevant spec file (e.g. `DevnetRevocationSpec.hs`).
2. Define an `action :: HarvestFlow -> IO SubmitResult` that
   constructs the mutation (e.g. "submit a settlement with the
   revoked reificator").
3. Assert `result `shouldSatisfy` isRejected`. Do not match on the
   error string — SC-005.

For positive scenarios:

1. Use the `HarvestFlow` harness state to thread the coalition UTxO
   and per-customer UTxOs through the test.
2. After submitting, re-query UTxOs via `Provider.queryUTxOs` and
   assert on the resulting shape (counter value, presence/absence,
   datum contents).

## Bisect-safe rule

Every commit on `003-devnet-full-flow` must keep `just ci` green.
If an intermediate commit would not satisfy this (e.g. the Aiken
validator has been updated but the Haskell encoder hasn't), split
the change: land the additive helper first, then the switch, then
the removal of any now-dead path. This matches the repository's
general bisect-safe commit rule from the workflow skill.

## Devnet prerequisites

Same as #15 — `cardano-node` 10.7.1 must be on `PATH`. `flake.nix`
pins this transitively through the `cardano-node-clients:devnet`
input.

If `withDevnet` fails to start, the first thing to check is that you
entered the nix dev shell (`direnv allow`) in this worktree. Each
worktree needs direnv permission independently.

## Interpreting failures

- **`DevnetFullFlowSpec` Story 1 regression**: a break in the
  coalition-ref plumbing, the voucher datum extension, or the
  settlement validator changes. Investigate before moving on —
  every other story depends on Story 1's baseline.
- **Revert or redemption rejections on the happy path**: often a
  signature domain-separator mismatch (`"REDEEM"` / `"REVERT"` tag).
  Start by printing the signed bytes on both Haskell and Aiken
  sides to compare.
- **Revocation happy path accepts but subsequent settlement also
  accepts**: the reificator-set membership check in `voucher_spend`
  is not wired to the coalition reference input. This is the most
  likely class of regression; grep for the ref-input lookup in the
  validator.
- **Devnet startup hangs**: check the nix dev shell is active and
  `cardano-node --version` reports 10.7.1. Upstream version drifts
  in `cardano-node-clients` have occasionally caused this; re-pin to
  the commit that `just ci` was last green on and open a dep-bump
  ticket per the workflow skill.
