use cardano/address.{Address}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{InlineDatum, Input, Output, OutputReference, Transaction}
use voucher/groth16
use voucher/types.{SpendRedeemer, VerificationKey, VoucherDatum}

/// Voucher spend validator.
///
/// Verifies a Groth16 proof that:
///   1. The user knows a secret matching user_id
///   2. The user holds a valid issuer-signed certificate for this user_id
///   3. The spend amount d plus the old counter doesn't exceed the cap
///   4. The committed counters are correctly computed
///
/// The supermarket submits the transaction — the user has no wallet.
validator voucher_spend(vk: VerificationKey) {
  spend(
    datum: Option<VoucherDatum>,
    redeemer: SpendRedeemer,
    own_ref: OutputReference,
    self: Transaction,
  ) {
    expect Some(voucher) = datum

    // Public inputs match the circuit:
    //   [d, commit_S_old, commit_S_new, user_id, issuer_Ax, issuer_Ay]
    let public_inputs =
      [
        redeemer.d,
        voucher.commit_spent,
        redeemer.commit_spent_new,
        voucher.user_id,
        redeemer.issuer_ax,
        redeemer.issuer_ay,
      ]

    // Verify the Groth16 proof
    let proof_valid = groth16.verify(vk, redeemer.proof, public_inputs)

    // Check that the output UTXO has the updated commitment
    let output_valid =
      check_output(self, own_ref, voucher.user_id, redeemer.commit_spent_new)

    proof_valid && output_valid
  }

  else(_ctx: ScriptContext) {
    False
  }
}

/// Verify the continuing output has the updated datum.
fn check_output(
  tx: Transaction,
  own_ref: OutputReference,
  user_id: Int,
  new_commit: Int,
) -> Bool {
  expect Some(own_input) =
    tx.inputs |> find_input(own_ref)

  let own_address = own_input.output.address

  expect Some(output) =
    tx.outputs |> find_output_at(own_address)

  expect InlineDatum(raw_datum) = output.datum
  expect datum: VoucherDatum = raw_datum
  datum.user_id == user_id && datum.commit_spent == new_commit
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

fn find_output_at(
  outputs: List<Output>,
  addr: Address,
) -> Option<Output> {
  when outputs is {
    [] -> None
    [output, ..rest] ->
      if output.address == addr {
        Some(output)
      } else {
        find_output_at(rest, addr)
      }
  }
}
