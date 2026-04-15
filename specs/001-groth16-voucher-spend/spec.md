# Feature Specification: Voucher Spend

**Feature Branch**: `001-groth16-voucher-spend`
**Created**: 2026-04-14
**Status**: Draft
**Input**: User description: "A user presents a zero-knowledge proof proving they can spend a specific amount from a coalition-issued voucher without revealing their balance or cap. The supermarket submits the transaction on-chain."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Spend Vouchers (Priority: P1)

A customer wants to spend loyalty vouchers. Their phone app generates a zero-knowledge proof for the chosen amount. The proof is passed to a coalition member (supermarket), which submits the spend transaction to the ledger. The customer's committed spend counter updates on-chain. Neither the submitting supermarket nor the public ledger learns the customer's total balance or cap — only the amount spent.

**Why this priority**: This is the core interaction. Without a working spend, nothing else matters.

**Independent Test**: Can be fully tested by simulating a spend with known test values (cap=100, already spent=25, spending 10 more) and verifying the ledger state updates correctly and the proof is accepted.

**Acceptance Scenarios**:

1. **Given** a customer with a valid voucher certificate (cap 100, already spent 25), **When** they present a proof to spend 10, **Then** the transaction succeeds and the ledger records the new committed counter (spent 35).
2. **Given** the same customer, **When** the transaction completes, **Then** no on-chain observer can determine the customer's cap (100) or remaining balance (65) — only that 10 was spent.
3. **Given** a customer trying to spend more than their remaining balance, **When** they attempt to generate a proof for an amount exceeding cap minus spent, **Then** proof generation fails on the phone — no invalid transaction is submitted.

---

### User Story 2 - Cross-Member Spending (Priority: P1)

A customer earned vouchers at supermarket A but spends them through supermarket B (a different coalition member). The spend flow is identical from the customer's perspective. Supermarket B submits the transaction. The ledger tracks the spend under supermarket A's issuer entry.

**Why this priority**: Cross-member spending is the reason the coalition exists. If vouchers only work at the issuing supermarket, there is no coalition value.

**Independent Test**: Can be tested by issuing a certificate from issuer A and spending it through a submission by member B. The ledger must accept the proof and update the correct issuer A entry.

**Acceptance Scenarios**:

1. **Given** a customer with a voucher from issuer A, **When** they spend through member B, **Then** the transaction succeeds and issuer A's entry for this customer is updated.
2. **Given** a customer with a voucher from issuer X (not in the coalition), **When** they attempt to spend through member B, **Then** the transaction is rejected — issuer X is not in the accepted list.

---

### User Story 3 - Supermarket Submits on Behalf of Customer (Priority: P1)

The customer has no blockchain wallet or funds. The customer's phone generates the proof. The supermarket receives the proof and submits the transaction using its own wallet and funds. The customer never interacts with the blockchain.

**Why this priority**: Requiring customers to have wallets would kill adoption. The supermarket absorbs the submission cost as part of the loyalty program operating expense.

**Independent Test**: Can be tested by generating a proof offline (simulating the phone), passing it to a submitter (simulating the supermarket), and verifying the transaction lands on the ledger signed only by the supermarket.

**Acceptance Scenarios**:

1. **Given** a valid proof from the customer's phone, **When** the supermarket submits it, **Then** the transaction succeeds without any customer signature or wallet.
2. **Given** a valid proof, **When** submission fails due to network issues, **Then** the supermarket can retry with the same proof (idempotent within the same ledger state).

---

### User Story 4 - Multiple Spends Over Time (Priority: P2)

A customer makes several spends over days/weeks. Each spend increments their committed counter. The customer's phone tracks the running total privately and generates correct proofs each time.

**Why this priority**: The system must handle ongoing usage, not just a single spend. The monotonic counter must work correctly across many transactions.

**Independent Test**: Can be tested by sequentially spending 10, then 20, then 15 from a cap of 100, verifying each ledger update and that the final committed counter reflects 45 total spent.

**Acceptance Scenarios**:

1. **Given** a customer who has already spent 25 from a cap of 100, **When** they spend 10, then later spend 20, **Then** both transactions succeed and the committed counter reflects 55 total.
2. **Given** a customer who has spent 95 from a cap of 100, **When** they try to spend 10, **Then** proof generation fails — the phone prevents overspending.

---

### User Story 5 - Multi-Issuer Spend (Priority: P3)

A customer holds vouchers from multiple issuers (A, B, C). In a single transaction, they spend from more than one issuer — for example, 30 from issuer A and 20 from issuer B. One transaction, multiple proofs, multiple counter updates.

**Why this priority**: Combines balances across issuers in a single interaction. Important for the coalition experience but not required for MVP.

**Independent Test**: Can be tested by generating proofs for two issuers in one transaction and verifying both counters update.

**Acceptance Scenarios**:

1. **Given** a customer with vouchers from issuers A and B, **When** they spend 30 from A and 20 from B in one transaction, **Then** both counters update and the total spend is 50.
2. **Given** the same scenario, **When** issuer B's cap would be exceeded, **Then** the entire transaction fails — no partial updates.

---

### Edge Cases

- What happens when the customer's phone loses state (certificates, randomness)? — The customer must contact the issuing supermarket to re-derive their certificate. The on-chain committed counter remains as the source of truth for spent amounts.
- What happens when two supermarkets submit spends for the same customer simultaneously? — Both transactions attempt to consume the same on-chain state. One succeeds, the other fails due to state conflict. The failed submitter can inform the customer to regenerate the proof against the updated state.
- What happens when a coalition member is removed from the accepted list? — Existing spent counters for that issuer remain on the ledger but no new spends can be made against certificates from the removed issuer.
- What happens when the customer's proof is valid but the ledger state has changed between proof generation and submission? — The transaction fails due to state mismatch. The customer regenerates the proof against the current committed counter.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST allow a customer to spend a chosen amount from a single issuer's voucher balance in one transaction.
- **FR-002**: The system MUST reject any spend where the total spent would exceed the voucher cap, without revealing either value publicly.
- **FR-003**: The system MUST verify that the issuer who signed the voucher certificate is in the coalition's accepted list.
- **FR-004**: The system MUST update the customer's committed spend counter on the shared ledger after a successful spend.
- **FR-005**: The customer's phone MUST generate the proof locally without requiring network access to any coalition member's server.
- **FR-006**: The supermarket MUST be able to submit the spend transaction using only its own wallet — no customer wallet or signature required.
- **FR-007**: The system MUST ensure that only the spend amount is publicly visible on the ledger — the cap, total spent, and remaining balance remain private.
- **FR-008**: The ledger MUST enforce double-spend prevention: the same committed counter state cannot be consumed by two transactions. Concurrent submissions for the same customer naturally conflict — one succeeds, the other fails.
- **FR-009**: The system MUST support spends against any accepted issuer's vouchers, submitted by any coalition member.
- **FR-010**: The on-chain verification cost MUST fit within a single transaction's resource limits.

### Key Entities

- **Voucher Certificate**: An off-chain credential binding a customer identity, a voucher cap, and an issuer's signature. Held on the customer's phone. Never published on-chain.
- **Committed Spend Counter**: An on-chain commitment (hiding the actual value) representing how much a customer has spent from a specific issuer's vouchers. Updated with each spend.
- **Coalition Accepted List**: The on-chain registry of issuer identities whose vouchers are accepted for spending. Managed by the coalition.
- **Spend Proof**: A zero-knowledge proof generated by the customer's phone, proving the spend is valid (correct arithmetic, within cap, authentic certificate) without revealing private values.
- **Issuer**: A coalition member who signs voucher certificates for customers. Identified by a verification key in the accepted list.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A spend transaction completes successfully end-to-end: proof generation on device, submission by supermarket, ledger update confirmed.
- **SC-002**: An invalid spend (exceeding cap, wrong issuer, tampered proof) is rejected by the ledger with no state change.
- **SC-003**: Cross-member spending works: a voucher issued by member A is successfully spent through member B.
- **SC-004**: The customer's cap and remaining balance cannot be derived from any combination of on-chain data.
- **SC-005**: The on-chain verification fits within the ledger's per-transaction resource limits with room for the surrounding transaction logic.
- **SC-006**: Sequential spends from the same customer accumulate correctly, with each proof building on the previous committed counter.

## Assumptions

- The coalition's accepted issuer list is already populated (coalition management is a separate feature).
- The customer already holds a valid voucher certificate from a coalition member (issuance/reward is a separate feature).
- The customer's phone app exists and can generate proofs and present them to the supermarket's system (app development is out of scope — this spec covers the protocol, not the UI).
- Each issuer performs its own trusted setup for proof generation parameters.
- L1 throughput limits the number of spends the system can process. Scaling beyond L1 capacity is an open design problem documented in the constitution.
- Settlement timing makes real-time point-of-sale redemption an open UX problem. The protocol is correct for scenarios where settlement delay is acceptable (online orders, pre-committed spends, low-value redemptions where double-spend risk is accepted).
