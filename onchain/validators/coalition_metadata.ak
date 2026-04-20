use aiken/builtin
use aiken/crypto
use aiken/primitive/bytearray
use cardano/address.{Address}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction,
}
use harvest/coalition_types.{
  AddReificator, AddShop, CoalitionDatum, GovernanceRedeemer, RevokeReificator,
}

/// Coalition-metadata spend validator.
///
/// Authorises governance transitions on the coalition registry UTxO. See
/// `specs/003-devnet-full-flow/contracts/coalition-metadata-datum.md`
/// §Validator checks for the authoritative check list.
validator coalition_metadata {
  spend(
    datum: Option<CoalitionDatum>,
    redeemer: GovernanceRedeemer,
    own_ref: OutputReference,
    self: Transaction,
  ) {
    expect Some(input_datum) = datum

    // (1) Exactly one input at this script's address (no batching).
    expect Some(own_input) = find_input(self.inputs, own_ref)
    let own_address = own_input.output.address
    expect count_inputs_at(self.inputs, own_address) == 1

    // (2) Exactly one output at this script's address.
    expect [output] = outputs_at(self.outputs, own_address)
    expect InlineDatum(raw_output_datum) = output.datum
    expect output_datum: CoalitionDatum = raw_output_datum

    // Per-redeemer: (5)/(6) membership check, op-tag byte, and expected
    // transitioned state.
    let (target_pk, issuer_sig, op_tag, expected_datum) =
      when redeemer is {
        AddShop { target_pk, issuer_sig } -> {
          expect !contains(input_datum.shop_pks, target_pk)
          let new_shops = insert_sorted(input_datum.shop_pks, target_pk)
          (
            target_pk,
            issuer_sig,
            #"00",
            CoalitionDatum {
              shop_pks: new_shops,
              reificator_pks: input_datum.reificator_pks,
              issuer_pk: input_datum.issuer_pk,
            },
          )
        }
        AddReificator { target_pk, issuer_sig } -> {
          expect !contains(input_datum.reificator_pks, target_pk)
          let new_reifs = insert_sorted(input_datum.reificator_pks, target_pk)
          (
            target_pk,
            issuer_sig,
            #"01",
            CoalitionDatum {
              shop_pks: input_datum.shop_pks,
              reificator_pks: new_reifs,
              issuer_pk: input_datum.issuer_pk,
            },
          )
        }
        RevokeReificator { target_pk, issuer_sig } -> {
          expect contains(input_datum.reificator_pks, target_pk)
          let new_reifs = remove_first(input_datum.reificator_pks, target_pk)
          (
            target_pk,
            issuer_sig,
            #"02",
            CoalitionDatum {
              shop_pks: input_datum.shop_pks,
              reificator_pks: new_reifs,
              issuer_pk: input_datum.issuer_pk,
            },
          )
        }
      }

    // (3) Continuing output datum matches the transitioned state.
    // Sorted + unique by construction of `insert_sorted`; `issuer_pk`
    // preserved by all three branches above.
    expect output_datum == expected_datum

    // (4) Ed25519 signature by issuer_pk over
    //     serialise(own_ref) || op_tag || target_pk.
    //
    // Signing over the consumed UTxO's OutputReference rather than
    // `self.id` dodges the circular dependency of txid signing: the
    // redeemer hashes into `script_data_hash`, which hashes into
    // `tx.id`, so a signature over `tx.id` can never be computed by
    // the submitter. `own_ref` is unique per UTxO and is known at
    // tx-build time, giving replay protection for free.
    let own_ref_bytes = builtin.serialise_data(own_ref)
    let message =
      own_ref_bytes
        |> bytearray.concat(op_tag)
        |> bytearray.concat(target_pk)
    crypto.verify_ed25519_signature(
      input_datum.issuer_pk,
      message,
      issuer_sig,
    )
  }

  else(_ctx: ScriptContext) {
    False
  }
}

fn find_input(inputs: List<Input>, ref: OutputReference) -> Option<Input> {
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

fn count_inputs_at(inputs: List<Input>, addr: Address) -> Int {
  when inputs is {
    [] -> 0
    [input, ..rest] ->
      if input.output.address == addr {
        1 + count_inputs_at(rest, addr)
      } else {
        count_inputs_at(rest, addr)
      }
  }
}

fn outputs_at(outputs: List<Output>, addr: Address) -> List<Output> {
  when outputs is {
    [] -> []
    [output, ..rest] ->
      if output.address == addr {
        [output, ..outputs_at(rest, addr)]
      } else {
        outputs_at(rest, addr)
      }
  }
}

fn contains(xs: List<ByteArray>, needle: ByteArray) -> Bool {
  when xs is {
    [] -> False
    [x, ..rest] ->
      if x == needle {
        True
      } else {
        contains(rest, needle)
      }
  }
}

/// Insert `target` into a sorted-unique list. Caller has verified
/// `target` is not already present.
fn insert_sorted(xs: List<ByteArray>, target: ByteArray) -> List<ByteArray> {
  when xs is {
    [] -> [target]
    [x, ..rest] ->
      if bytearray.compare(target, x) == Less {
        [target, x, ..rest]
      } else {
        [x, ..insert_sorted(rest, target)]
      }
  }
}

fn remove_first(xs: List<ByteArray>, target: ByteArray) -> List<ByteArray> {
  when xs is {
    [] -> []
    [x, ..rest] ->
      if x == target {
        rest
      } else {
        [x, ..remove_first(rest, target)]
      }
  }
}
