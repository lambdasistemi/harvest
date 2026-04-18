# Quickstart: Running the E2E Tests

## Run the tests

All tests run under the existing standard gate:

```bash
just ci
```

This runs `checks.unit-tests`, which now includes `DevnetSpendSpec`, `Ed25519Spec`, and `SignedDataLayoutSpec`. `DevnetSpendSpec` spins up a devnet inside the test process; no external setup needed beyond a working `cardano-node` binary in the derivation's closure (already wired by the flake).

To run only the new E2E tests:

```bash
nix build .#checks.x86_64-linux.unit-tests --no-link
```

## Prerequisites

The devnet subprocess requires the `cardano-node` binary. `flake.nix` exposes it to the unit-tests check derivation; you do not need to install it separately. On a developer machine running `cabal test` directly, ensure the nix dev shell is active so `cardano-node` is on `PATH`.

## Regenerate fixtures (after circuit or signer change)

```bash
# 1. Regenerate the circuit fixtures
cd circuits && node generate_fixtures.js

# 2. Copy JSON fixtures to the offchain test tree
cp build/fixtures/{proof,public,verification_key,customer}.json ../offchain/test/fixtures/

# 3. If the circuit changed, re-apply the VK to produce a new applied-script.hex
#    (see existing aiken blueprint apply flow in docs)

# 4. Verify everything still passes
just ci
```

The Haskell tests read the JSON/hex fixtures at runtime, so step 4 immediately re-validates the whole pipeline. There is no generator to re-run between step 3 and step 4.

## Adding a new negative test

Per the standing rule (SC-005), any new validator check needs a paired negative test. Workflow:

1. In `DevnetSpendSpec.hs`, define `mutateYourCheck :: SpendBundle -> SpendBundle` that minimally corrupts the input that should trigger the new check's rejection.
2. Add a new `it` block that builds and submits a tx from the mutated bundle.
3. Assert the submission is rejected — using whatever "not accepted" observable cardano-node-clients gives you (typically an `ApplyTxError` surface on `submitTx`).
4. Do not match on specific error text; the ledger may reword errors across versions.
5. Leave the golden-path test untouched; reviewers diff the two scenarios to see the mutation.

## If cardano-node-clients needs a patch

If FR-003 (independent Ed25519 verify) finds the required primitive is not exported from `cardano-node-clients`' public surface:

1. `cd /code/cardano-node-clients` and create a worktree for the patch branch.
2. Add the minimal export (e.g. extending `Cardano.Node.Client.E2E.Setup` or a new public module) — smallest possible surface.
3. Open a PR upstream; wait for merge to main.
4. In harvest's `cabal.project`, pin the merged main commit with `source-repository-package` + `--sha256:` comment (nix32 format, computed via `nix flake prefetch`).
5. Re-run `just ci` locally to confirm the pinned version builds.
6. Open harvest's PR referencing the upstream merge commit.

## Interpreting failures

- **DevnetSpendSpec golden test fails**: investigate immediately. Something in the pipeline broke — circuit, validator, tx builder, or fixtures.
- **DevnetSpendSpec negative test accepts (when it should reject)**: the corresponding validator check is disabled or weakened. The test has done its job.
- **Ed25519Spec fails**: Node's Ed25519 output is not byte-compatible with the canonical verifier. Plutus will reject too.
- **SignedDataLayoutSpec fails**: byte-layout disagreement between Node signer and the parsing rules in `contracts/signed-data-layout.md`. Start with the contract doc.
- **Devnet fails to start**: `cardano-node` not in PATH or wrong version. Re-enter the nix dev shell.
