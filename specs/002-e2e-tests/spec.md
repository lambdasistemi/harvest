# Feature Specification: End-to-End Tests for Harvest Spending

**Feature Branch**: `002-e2e-tests`
**Created**: 2026-04-18
**Status**: Draft
**Input**: User description: "End-to-end tests for harvest validator, Groth16 verifier, and customer Ed25519 signature path"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Validator accepts a correctly-formed spend (Priority: P1)

The harvest spending protocol is implemented across three independent surfaces: a Groth16 zero-knowledge proof system, a customer Ed25519 signature over a canonical per-transaction payload, and an on-chain validator that composes both. Today no automated test confirms that a well-formed spend — the one the user's phone is expected to produce — is actually accepted by the deployed validator. A shipped feature must prove this at least once, automatically, on every CI run.

**Why this priority**: Without a golden-path test, any future change to the circuit, the signature layout, the validator logic, or the ledger interface can silently break real spends. This is the single test that separates "code compiles" from "spends work".

**Independent Test**: Can be fully tested by running the project's test command; success is the automated test reporting that the deployed validator returned accept for the fixture-produced spend bundle.

**Acceptance Scenarios**:

1. **Given** a correctly-produced spend bundle (proof, customer signature, signed payload, redeemer values) that a legitimate customer phone would generate, **When** the deployed on-chain spending validator is executed against the bundle, **Then** the validator returns accept.
2. **Given** the same spend bundle, **When** any independent Ed25519 verifier (a library outside the on-chain implementation) is given the customer's public key, the signed payload, and the signature, **Then** the verifier returns valid.
3. **Given** the customer's signed payload bytes as produced by the phone-side signer, **When** the five bound fields are extracted according to the documented canonical layout, **Then** every extracted field exactly matches the value the signer claims it set.

---

### User Story 2 - Validator rejects a tampered spend (Priority: P1)

Every check performed by the validator must be independently exercised by a negative test that proves the check has teeth. A test that only exercises the golden path is satisfied by a validator that always returns accept — which is useless. For each documented rejection reason, there must be a test that mutates the spend bundle to trigger that exact reason and observes the validator rejecting.

**Why this priority**: Positive tests without paired negative tests are common silent-pass bugs. The standing rule for this repository is that every positive test must be accompanied by a mutation that proves the test can fail. This is what "exercising the validator" actually means.

**Independent Test**: Can be fully tested by running the project's test command with each mutation applied in turn; success is the automated test reporting that the deployed validator returned reject for every mutation.

**Acceptance Scenarios**:

1. **Given** a correctly-produced spend bundle, **When** any byte of the signed payload is flipped before submission, **Then** the validator rejects (because the customer's signature no longer verifies).
2. **Given** a correctly-produced spend bundle, **When** the spend amount in the signed payload differs from the spend amount elsewhere in the redeemer, **Then** the validator rejects (defence-in-depth cross-check).
3. **Given** a correctly-produced spend bundle, **When** the raw customer public key bytes do not split to the hi/lo halves present in the redeemer, **Then** the validator rejects (proof-to-signature key match).
4. **Given** a correctly-produced spend bundle, **When** the transaction-output reference named in the signed payload is not among the transaction's consumed inputs, **Then** the validator rejects (replay-protection gate).

---

### User Story 3 - Cross-implementation byte layout agreement (Priority: P2)

The phone-side signer and the on-chain validator share a single piece of critical knowledge: the exact byte layout of the customer-signed payload. A silent disagreement here — one side using little-endian where the other expects big-endian, one side reserving 2 bytes for a field where the other reserves 4 — produces a validator that rejects all legitimate spends while still passing any tests that only read its own output. An automated cross-implementation check must confirm the two sides agree on the layout.

**Why this priority**: Bugs here are cheap to introduce and expensive to find in production because the validator just says "Ed25519 failed" with no signal about why. Catching the regression at CI time prevents a class of incidents where a refactor on one side desyncs silently.

**Independent Test**: Can be fully tested by running the project's test command; success is the automated test reporting that every field extracted from the phone-produced bytes, according to the validator's parsing rules, equals the value the phone claimed to set.

**Acceptance Scenarios**:

1. **Given** the phone-signed payload bytes and the phone's declared values for each of the five bound fields, **When** the payload is parsed using the same rules the validator applies, **Then** each parsed field equals the phone's declared value bit-for-bit.

---

### Edge Cases

- A fixture produced by one toolchain (the phone-side Ed25519 signer, the zero-knowledge prover) is consumed by a different toolchain (the on-chain validator, an independent Ed25519 library). Tests must survive cosmetic differences (whitespace, encoding) but catch semantic differences (byte order, field widths, curve or hash choice).
- The golden-path test must load the latest fixture every run, not a frozen copy, so that regenerating the fixture after a circuit or signer change immediately re-validates the whole pipeline.
- A negative test that mutates a byte must not rely on the mutated bundle triggering a specific error code — only on the validator rejecting. The specific rejection reason may change across validator refactors.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The test suite MUST include at least one automated test that executes the deployed on-chain spending validator against a correctly-produced spend bundle and asserts that it returns accept.
- **FR-002**: The test suite MUST include one automated test per documented validator rejection reason (tampered signed payload, spend-amount mismatch, customer-key split mismatch, transaction-input reference not consumed) that mutates a correct spend bundle exactly to trigger that reason and asserts the validator rejects.
- **FR-003**: The test suite MUST include an automated test that verifies the customer's Ed25519 signature over the canonical signed payload using an Ed25519 library independent of the on-chain implementation, proving that the phone-produced bytes are consumable by a general-purpose Ed25519 verifier.
- **FR-004**: The test suite MUST include an automated cross-implementation check that extracts all five bound fields (transaction id, output index, acceptor key x, acceptor key y, spend amount) from the phone-produced payload bytes using the same layout rules the validator applies, and asserts each extracted value equals the value the phone-side signer set.
- **FR-005**: The test suite MUST fail the project's standard test command (the same command that gates merges) if any of FR-001 through FR-004 fails — these tests MUST NOT be skippable, pending, or opt-in.
- **FR-006**: The test suite MUST consume the same fixture artifacts the project already regenerates from the circuit and the customer Ed25519 keypair; it MUST NOT maintain a parallel copy of the fixtures that can drift from the authoritative ones.
- **FR-007**: Negative tests MUST assert rejection without depending on specific error messages or exit codes beyond "validator did not accept", so future validator refactors do not spuriously break the tests.
- **FR-008**: Every negative test MUST be paired with its positive test (the unmutated bundle accepted), so reviewers can see at a glance that the mutation caused the rejection and the mutation alone is the difference.

### Key Entities *(include if feature involves data)*

- **Spend bundle**: The complete set of inputs a reificator submits to the validator on behalf of a customer. Composed of a zero-knowledge proof, a customer-signed canonical payload, the customer's public key material, and a transaction-output reference the reificator commits to consuming.
- **Signed payload**: The canonical byte sequence over which the customer's Ed25519 signature is computed. Carries the per-transaction binding of acceptor identity, spend amount, and transaction-output reference. The byte layout is the sole shared secret between the phone-side signer and the on-chain validator.
- **Mutation**: An intentional deviation from a known-good spend bundle used to exercise a single validator rejection path.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A regression that breaks the golden-path spend (the one a legitimate phone would produce) is caught by the test suite on the first affected commit, before the change can be merged.
- **SC-002**: A regression that disables any individual validator rejection check is caught by the corresponding negative test on the first affected commit.
- **SC-003**: A silent byte-layout disagreement between the phone-side signer and the on-chain parser (for any of the five bound fields) is caught by an automated cross-check on the first affected commit.
- **SC-004**: A fixture regeneration (after a circuit or signer change) is immediately re-validated through the entire pipeline by rerunning the standard test command — no manual step is required to refresh the tests' knowledge of the fixture.
- **SC-005**: After this feature ships, no future spend-protocol feature may be declared shipped without an analogous end-to-end test; this becomes the standing bar for this repository.

## Assumptions

- The project's standard test command is the same command that gates merges today; the new tests plug into that command rather than living in a separate, easily-forgotten script.
- Authoritative fixtures already exist (produced by the circuit toolchain and by the phone-side Ed25519 signer during the previous feature); the new tests consume them as-is rather than creating parallel copies.
- An Ed25519 library independent of the on-chain validator is already available to the project as a standard cryptographic dependency; no new third-party dependency is introduced solely for these tests.
- The applied validator script — the bytecode that will actually run on-chain — is already produced by the project's build and available as a consumable artifact.
- "Validator rejects" is an observable outcome: the test runner can distinguish acceptance from rejection without knowing implementation details of the validator.
- The set of documented rejection reasons is fixed by FR-002 (four reasons). If a future validator change adds a rejection reason, FR-002 expands accordingly and a new negative test is required; this is expected behaviour of the standing rule in SC-005.
