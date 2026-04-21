use aiken/builtin
use aiken/crypto
use aiken/primitive/bytearray
use cardano/address.{Address, Script}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{InlineDatum, Input, Output, OutputReference, Transaction}
use harvest/coalition_types.{CoalitionDatum}
use voucher/types.{RedeemRedeemer, VoucherDatum}

/// Voucher redemption validator.
///
/// Authoritative check list: `contracts/voucher-datum.md`
/// §Validator checks — redemption.
///
/// The reificator removes a voucher entry by proving coalition
/// membership and signing (own_ref.txid || "REDEEM") with the
/// datum's reificator_pk. No output may remain at this address
/// with the same user_id.
validator voucher_redeem(coalition_hash: ByteArray) {
  spend(
    datum: Option<VoucherDatum>,
    redeemer: RedeemRedeemer,
    own_ref: OutputReference,
    self: Transaction,
  ) {
    expect Some(voucher) = datum

    // --- (1) Coalition reference input present; parseable ---
    expect Some(coalition) =
      find_coalition_ref(self.reference_inputs, coalition_hash)

    // --- (2) datum.reificator_pk ∈ coalition.reificator_pks ---
    expect list_contains(coalition.reificator_pks, voucher.reificator_pk)

    // --- (3) blake2b_224(datum.reificator_pk) ∈ tx.extra_signatories ---
    let reificator_hash = crypto.blake2b_224(voucher.reificator_pk)
    expect list_contains(self.extra_signatories, reificator_hash)

    // --- (4) Ed25519 sig over (txid || "REDEEM") ---
    let message =
      bytearray.concat(own_ref.transaction_id, "REDEEM")
    expect
      crypto.verify_ed25519_signature(
        voucher.reificator_pk,
        message,
        redeemer.reificator_sig,
      )

    // --- (5) No output at this address with this user_id ---
    expect Some(own_input) =
      find_input(self.inputs, own_ref)
    let own_address = own_input.output.address
    no_voucher_output_at(self.outputs, own_address, voucher.user_id)
  }

  else(_ctx: ScriptContext) {
    False
  }
}

/// Find the coalition-metadata reference input by script hash and parse
/// its inline datum as a CoalitionDatum.
fn find_coalition_ref(
  ref_inputs: List<Input>,
  script_hash: ByteArray,
) -> Option<CoalitionDatum> {
  when ref_inputs is {
    [] -> None
    [input, ..rest] ->
      when input.output.address.payment_credential is {
        Script(hash) ->
          if hash == script_hash {
            when input.output.datum is {
              InlineDatum(raw) -> {
                expect cd: CoalitionDatum = raw
                Some(cd)
              }
              _ -> find_coalition_ref(rest, script_hash)
            }
          } else {
            find_coalition_ref(rest, script_hash)
          }
        _ -> find_coalition_ref(rest, script_hash)
      }
  }
}

/// Check whether a bytearray is in a list.
fn list_contains(xs: List<ByteArray>, x: ByteArray) -> Bool {
  when xs is {
    [] -> False
    [head, ..tail] ->
      if head == x {
        True
      } else {
        list_contains(tail, x)
      }
  }
}

fn find_input(
  inputs: List<Input>,
  ref: OutputReference,
) -> Option<Input> {
  when inputs is {
    [] -> None
    [input, ..rest] ->
      if input.output_reference == ref {
        Some(input)
      } else {
        find_input(rest, ref)
      }
  }
}

/// Verify no output at the given address carries a VoucherDatum with
/// the specified user_id. Returns True if no such output exists.
fn no_voucher_output_at(
  outputs: List<Output>,
  addr: Address,
  user_id: Int,
) -> Bool {
  when outputs is {
    [] -> True
    [output, ..rest] ->
      if output.address == addr {
        when output.datum is {
          InlineDatum(raw) -> {
            // If the datum parses as a VoucherDatum with matching user_id,
            // the check fails. If it doesn't parse (different datum type)
            // or has a different user_id, continue scanning.
            let conflicts = is_matching_voucher(raw, user_id)
            if conflicts {
              False
            } else {
              no_voucher_output_at(rest, addr, user_id)
            }
          }
          _ -> no_voucher_output_at(rest, addr, user_id)
        }
      } else {
        no_voucher_output_at(rest, addr, user_id)
      }
  }
}

/// Check whether a raw datum is a VoucherDatum (Constr 0) with the
/// given user_id. Returns False (no conflict) if the datum has a
/// different constructor tag or a different user_id.
///
/// Uses Plutus builtins to deconstruct the Data without crashing on
/// unexpected shapes (un_constr_data is safe here because InlineDatum
/// at a script address is always a Constr).
fn is_matching_voucher(raw: Data, user_id: Int) -> Bool {
  let pair = builtin.un_constr_data(raw)
  let tag = builtin.fst_pair(pair)
  if tag == 0 {
    let fields = builtin.snd_pair(pair)
    when fields is {
      [uid_data, ..] -> builtin.un_i_data(uid_data) == user_id
      _ -> False
    }
  } else {
    False
  }
}
