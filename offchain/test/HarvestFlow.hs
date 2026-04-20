{- |
Module      : HarvestFlow
Description : Test harness state threaded through the Devnet*Spec modules.

Per `specs/003-devnet-full-flow/data-model.md` §HarvestFlow harness.
Each Devnet*Spec owns its own @withDevnet@ bracket and threads a
'HarvestFlow' value to share coalition + per-customer UTxOs between
scenarios in the spec.

T002 — skeleton only. T011 adds the data type and
@bootstrapCoalition@.
-}
module HarvestFlow () where
