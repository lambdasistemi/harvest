use cardano/script_context.{ScriptContext}
use cardano/transaction.{OutputReference, Transaction}

/// Voucher redemption validator.
///
/// Authoritative check list: `contracts/voucher-datum.md`
/// §Validator checks — redemption.
///
/// T001 — skeleton only; uses `Data` placeholders. T028 rewrites the
/// signature against the extended `VoucherDatum` (T007) and a typed
/// `RedeemRedeemer`, and implements the body.
validator voucher_redeem {
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
