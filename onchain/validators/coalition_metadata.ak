use cardano/script_context.{ScriptContext}
use cardano/transaction.{OutputReference, Transaction}

/// Coalition-metadata spend validator.
///
/// Authorises coalition governance transitions: add shop, add
/// reificator, revoke reificator. See
/// `specs/003-devnet-full-flow/contracts/coalition-metadata-datum.md`
/// §Validator checks for the authoritative check list.
///
/// T001 — skeleton only; uses `Data` placeholders so this commit
/// compiles before `CoalitionDatum` / `GovernanceRedeemer` land in
/// T005. T006 rewrites the signature and body against those types.
validator coalition_metadata {
  spend(
    _datum: Option<Data>,
    _redeemer: Data,
    _own_ref: OutputReference,
    _self: Transaction,
  ) {
    False
  }

  else(_ctx: ScriptContext) {
    False
  }
}
