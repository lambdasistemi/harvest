# Harvest — Journey Dependency Graph

Generated 2026-04-20 from GitHub issue dependency edges in
`lambdasistemi/harvest`. Green = closed. White = open. Arrows point
in the direction **"must happen before"** — `A → B` reads "`A` blocks
`B`".

## Main journey (rooted at the tracker issue #3)

```mermaid
flowchart TD
    classDef done fill:#c8f7c5,stroke:#1a7f1a,color:#064006
    classDef open fill:#ffffff,stroke:#444,color:#111
    classDef research fill:#fff3bf,stroke:#a06800,color:#4a2f00
    classDef conflict stroke:#d9534f,stroke-width:2px,stroke-dasharray:4 3

    I4["#4 acceptor_pk as circuit public input"]:::done
    I10["#10 circuit + redeemer rework: customer Ed25519 sig"]:::done
    I15["#15 E2E: validator, Groth16, Ed25519 sig path"]:::done
    I16["#16 bump to cardano-node-clients@408a890"]:::done

    I5["#5 three-trie on-chain model (MPF)"]:::open
    I6["#6 spend lifecycle: settlement, redemption, revert"]:::open
    I7["#7 multi-certificate spend"]:::open
    I8["#8 MPFS integration"]:::open
    I9["#9 Devnet E2E: full protocol flow"]:::open
    I3(["#3 Journey: Harvest protocol implementation (epic)"]):::open

    I4 --> I10
    I4 --> I5
    I5 --> I6
    I6 --> I7
    I6 --> I8
    I8 -.conflict.-> I9:::conflict
    I16 --> I15

    I5 --> I3
    I6 --> I3
    I7 --> I3
    I8 --> I3
    I9 --> I3
    I4 --> I3
```

The dashed red edge `#8 → #9` is the **declared** blocker in GitHub,
but the current `003-devnet-full-flow` spec (this branch) explicitly
skips it — matching the path #15 took — and flags it as the top
`/speckit.clarify` topic.

## Parallel / side tracks

```mermaid
flowchart TD
    classDef done fill:#c8f7c5,stroke:#1a7f1a,color:#064006
    classDef open fill:#ffffff,stroke:#444,color:#111
    classDef research fill:#fff3bf,stroke:#a06800,color:#4a2f00

    I2["#2 replace snarkjs with circom-prover (Rust)"]:::open
    I12["#12 research: Poseidon-BLS12-381 in Aiken"]:::done
    I13["#13 research: v2 privacy redesign (nullifier-based)"]:::research
```

These three have no `blockedBy` / `blocking` edges. They are
independent workstreams and can be picked up without affecting the
main journey.

## Current state summary

| Status | Issues |
|---|---|
| **Merged** | #4, #10, #12 (research), #15, #16 |
| **In flight** | #9 (this branch `003-devnet-full-flow`) |
| **Open, next natural steps** | #5 (three-trie), #6 (lifecycle), #7 (multi-cert), #8 (MPFS) |
| **Side tracks** | #2 (prover rewrite), #13 (v2 privacy research) |
| **Tracker** | #3 |

## Where we are right now

```
#4 ✓ → #10 ✓ → #15 ✓  (single-spend E2E delivered)
            ↓
            #16 ✓ (dep bump — done during #15)
            ↓
#9 ◐ (in progress on this branch; spec pushed, plan next)
```

Everything downstream of the ledger work (`#5 three-trie` →
`#6 lifecycle` → `#7 multi-cert` / `#8 MPFS`) is still un-scoped in
code. `#9` cuts a horizontal slice — the full protocol flow end-to-
end — that exercises parts of #6 (settlement/redemption/revert
semantics) without waiting for the three-trie ledger implementation
(#5) to land. That's the deliberate scope decision captured as
FR-013/FR-014 in the spec.
