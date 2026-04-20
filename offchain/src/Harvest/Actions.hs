{- |
Module      : Harvest.Actions
Description : Pure state-machine twin of the Aiken validators.

Lean ↔ Haskell twin per
`specs/003-devnet-full-flow/contracts/actions.md`. The Lean side
(`lean/Harvest/Actions.lean`, scaffolded in the #9 Lean submission)
owns the invariants; this module mirrors the signatures and guard
semantics shape-for-shape.

T002 — skeleton only: module header, types wiring via @undefined@.
T008 fills in the state types, T013 / T014 implement transitions.
-}
module Harvest.Actions () where
