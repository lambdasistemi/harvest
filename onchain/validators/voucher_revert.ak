use cardano/script_context.{ScriptContext}
use cardano/transaction.{OutputReference, Transaction}

/// Voucher revert validator.
///
/// Authoritative check list: `contracts/voucher-datum.md`
/// §Validator checks — revert.
///
/// T001 — skeleton only; uses `Data` placeholders. T035 rewrites the
/// signature against the extended `VoucherDatum` (T007) and a typed
/// `RevertRedeemer`, and implements the body.
validator voucher_revert {
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
