# Phase 0 Research: End-to-End Tests

**Superseded version**: an earlier draft of this document planned tests via Aiken's own runner (`aiken check`) with an Aiken fixture module generated from a Haskell tool. That approach was replaced by the cardano-node-clients-first approach below, per the repository rule: *use cardano-node-clients primitives and patch it if our needs are not covered*.

## Decisions with rationale

### D1. Primary E2E path is a real devnet via `cardano-node-clients:devnet`

**Decision**: the validator is exercised by submitting real transactions to a real cardano-node on a devnet spun up inside each hspec test via `withDevnet` from `cardano-node-clients:devnet`.

**Rationale**: this is end-to-end in the strongest sense — the Haskell tx builder (`TxBuild`), the applied validator bytecode, Plutus builtins (Groth16 verify, `VerifyEd25519Signature`), ledger rules (fees, balance, script-integrity hash), and the node's consensus path are all exercised. `cardano-node-clients:devnet` is a `visibility: public` sub-library that other projects consume exactly this way; its own test suite uses the same pattern. No bytecode embedding, no context synthesis — we submit txs and watch the node.

**Alternatives rejected**:
- **`aiken check` with synthesised `Transaction`**: runs the Aiken bytecode but via Aiken's runner, not via the ledger. Doesn't exercise the Haskell tx builder, the applied-script serialization, or ledger rules. Does not satisfy the repository rule on cardano-node-clients primitives.
- **UPLC CEK evaluation via `plutus-core` directly**: we would reimplement the slice of node logic that turns a redeemer + datum + tx context into a script eval. cardano-node-clients already does this end-to-end via `Evaluate.evaluateAndBalance`; reimplementing is a silent fork of the rules.
- **Ledger emulator without a node**: heavier setup, plus not what cardano-node-clients offers. The project's whole point is to test against the real thing.

### D2. The test suite uses hspec + withDevnet bracket, one devnet per test file

**Decision**: `DevnetSpendSpec.hs` starts one devnet in `beforeAll`, tears it down in `afterAll`. All 5 scenarios (1 golden + 4 negatives) share the same devnet, creating fresh UTXOs per scenario. `Ed25519Spec` and `SignedDataLayoutSpec` do not need the devnet.

**Rationale**: devnet startup is the slow step (~10–20 s). Amortising it across 5 scenarios keeps the added CI time under a minute. UTXOs per-scenario are cheap; the fresh funding tx is ~2 s.

**Alternatives rejected**:
- One devnet per scenario: 5× the startup cost for no benefit; tests are still sequential.
- A single long-lived devnet shared across hspec files: cross-file state is a footgun; each file is self-contained.

### D3. Independent Ed25519 verify (FR-003) uses `cardano-node-clients` re-exports

**Decision**: harvest's Haskell tests import the Ed25519 verify primitive from `cardano-node-clients` (or its `devnet` sub-library). The underlying implementation is `cardano-crypto-class`'s `Ed25519DSIGN`. If the current public surface of `cardano-node-clients` does not re-export the verify function we need, we patch cardano-node-clients to expose it and pin the patched version here.

**Rationale**: the repository rule is to use cardano-node-clients primitives and patch upstream when they don't cover needs. That's the only way the surface stays consistent across projects that share this dep. `cardano-crypto-class` is already a transitive dep of cardano-node-clients; re-exporting a single verify function is a trivial surface addition.

**Alternatives rejected**:
- Depend directly on `cardano-crypto-class` in harvest's test-suite: bypasses the upstream boundary. Breaks the rule. If the Ed25519 API ever changes, we end up with two sources of truth.
- Use a different Ed25519 library (crypton, ed25519): fails "independent" (different impl) but more importantly introduces a new dep that isn't how the rest of the stack talks to Ed25519.

### D4. Patch target and flow for cardano-node-clients (if needed)

**Decision**: if an upstream patch is needed:
1. Create a worktree of `/code/cardano-node-clients`.
2. Add the smallest possible export to a public module — preferably `Cardano.Node.Client.E2E.Setup` (already public via the `devnet` sub-library) since that's where the Ed25519 key helpers already live.
3. Open a PR upstream, merge.
4. Pin the merged main commit in harvest's `cabal.project` via `source-repository-package` with a `--sha256:` comment in nix32 format, per the constitution rule *Pins main only*.
5. Run `just ci` locally to confirm the pinned version builds before opening the harvest PR.

**Rationale**: follows the existing patterns for cross-repo patches in this codebase. Respects the constitution rule that pins must target main commits, never branches.

**Alternatives rejected**:
- Vendoring `cardano-crypto-class`'s verify into harvest: creates a second source of truth for Ed25519 verification inside this codebase. Fails the rule.
- Calling internal cardano-node-clients modules via `-package cardano-node-clients -any`: works technically, rots quickly, and sends the wrong signal about the repository's policy on upstream primitives.

### D5. Negative tests mutate the golden bundle in-place

**Decision**: each of the 4 negative scenarios takes the golden fixture bundle and mutates one input before submission. The 4 mutations match the 4 documented rejection reasons (FR-002):
1. Flip a byte in `signed_data` → Ed25519 verify fails at the validator.
2. Set `redeemer.d` to `signed_data.d + 1` → the validator's defence-in-depth cross-check fails.
3. Replace `redeemer.customer_pubkey` with a different 32-byte blob whose hi/lo halves don't match `redeemer.pk_c_hi` / `redeemer.pk_c_lo` → the validator's key-match check fails.
4. Build the tx consuming a different UTXO than the one named in `signed_data` → the validator's "TxOutRef in tx.inputs" check fails.

**Rationale**: minimal surface, one mutation per scenario, positive/negative diff is obvious to a reviewer (FR-008). Assertions check only "validator did not accept" (FR-007); they do not match on specific error strings or exit codes, which the ledger may reword across versions.

### D6. Fixture source of truth is the existing JSON/hex files

**Decision**: tests read `offchain/test/fixtures/proof.json`, `verification_key.json`, `public.json`, `customer.json`, and `applied-script.hex` directly. No new generated files. No fixture generator.

**Rationale**: with the devnet approach, we do not need hex constants embedded in an Aiken module — the Haskell tests drive everything. The JSON/hex files are already authoritative (FR-006). Any fixture regeneration (circuit change, signer change) is immediately picked up by the tests on the next CI run.

**Alternatives rejected**:
- Haskell-generated Aiken fixture module: obsolete under the devnet approach.

### D7. `cardano-node` binary availability in the check derivation

**Decision**: `checks.unit-tests` in `flake.nix` gains `cardano-node` as a `buildInputs` / `nativeBuildInputs` entry so `withDevnet` can find the executable. The specific version pin comes from the same source cardano-node-clients' own tests use.

**Rationale**: `withDevnet` spawns `cardano-node` as a subprocess. The CI environment must make it available. We use exactly the version cardano-node-clients pins to avoid version drift between harvest's tests and the upstream tests.

**Alternatives rejected**:
- Shipping cardano-node as a git submodule: unnecessary — it's a standard Cardano dep available in nix.
- Running the tests without a real node (mock submitter): we lose every property the devnet gives us.

## Audit findings (from T001, 2026-04-18)

Upstream commit audited: `867cb01 Test against Preview node 10.7.0 and align dependencies` on `/code/cardano-node-clients` main.

**Available in public surface (no patch needed)**:
- `Cardano.Node.Client.E2E.Setup` (in `:devnet` sub-library): `withDevnet`, `mkSignKey`, `keyHashFromSignKey`, `enterpriseAddr`, `addKeyWitness`, `genesisSignKey`, `genesisAddr`, `devnetMagic`, `genesisDir`.
- `Cardano.Node.Client.Submitter` (main library): `Submitter`, `SubmitResult (Submitted TxId | Rejected ByteString)`, `submitTx`. The `SubmitResult` sum type gives us exactly the accept/reject observable FR-007 calls for.
- `Cardano.Node.Client.Provider`: `Provider`, `queryUTxOs`, `EvaluateTxResult`.
- `Cardano.Node.Client.Evaluate`: `evaluateAndBalance`.
- `Cardano.Node.Client.TxBuild`: already used by `Harvest.Transaction`.
- `Cardano.Node.Client.E2E.ChainPopulator` (in `:devnet`): funding helpers.

**Missing from public surface (patch needed)**:
- `verifyDSIGN`, `VerKeyDSIGN Ed25519DSIGN`, `SigDSIGN Ed25519DSIGN`, and the raw-byte deserializers (`rawDeserialiseVerKeyDSIGN`, `rawDeserialiseSigDSIGN`) are NOT re-exported from `Cardano.Node.Client.E2E.Setup`. They live in `cardano-crypto-class` and are imported internally by `Setup.hs` but not part of its export list.

**Patch decision (T006 required)**: extend `Cardano.Node.Client.E2E.Setup`'s export list with an `-- * Ed25519 verification` section that re-exports `verifyDSIGN`, `VerKeyDSIGN`, `SigDSIGN`, `rawDeserialiseVerKeyDSIGN`, `rawDeserialiseSigDSIGN`, `Ed25519DSIGN`, and `SignKeyDSIGN` (some already public via imports re-exports; we make it explicit). Zero logic change, only re-exports. Targets `Cardano.Node.Client.E2E.Setup` because (a) it's public, (b) the Ed25519 key primitives already live there, (c) adding a verify section is the natural grouping.

## Open items

- Whether harvest's tx builder needs adjustment for the devnet scenario: no adjustment anticipated — `spendVoucher` in `Harvest.Transaction` already uses the shared `TxBuild` DSL. Will confirm when integrating in T020.
