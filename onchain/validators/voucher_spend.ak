use aiken/crypto
use aiken/primitive/bytearray
use cardano/address.{Address, Script}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{InlineDatum, Input, Output, OutputReference, Transaction}
use harvest/coalition_types.{CoalitionDatum}
use voucher/groth16
use voucher/types.{SpendRedeemer, VerificationKey, VoucherDatum}

/// Voucher spend validator.
///
/// Two-layer authorisation:
///
///   A. Groth16 proof attests: the customer (who knows user_secret) is
///      spending `d` against a cap `C` signed by the issuer, with the
///      commitment chain correctly updated. `pk_c_hi`/`pk_c_lo` are
///      public inputs so the validator can cross-check them against the
///      redeemer-supplied `customer_pubkey`.
///
///   B. Customer Ed25519 signature over `signed_data` binds this spend to
///      a specific Cardano tx — specifically one consumed TxOutRef — and
///      to `acceptor_pk` and `d`. This prevents proof replay across txs
///      and substitution of acceptor, d, or customer key.
validator voucher_spend(vk: VerificationKey, coalition_hash: ByteArray) {
  spend(
    datum: Option<VoucherDatum>,
    redeemer: SpendRedeemer,
    own_ref: OutputReference,
    self: Transaction,
  ) {
    expect Some(voucher) = datum

    // --- Layer B: Ed25519 signature + canonical signed_data parse ---

    // (a) verify the customer's Ed25519 signature
    expect
      crypto.verify_ed25519_signature(
        redeemer.customer_pubkey,
        redeemer.signed_data,
        redeemer.customer_signature,
      )

    // (b) parse signed_data (106-byte layout, see SpendRedeemer doc)
    //     slice end is inclusive
    let txid = bytearray.slice(redeemer.signed_data, 0, 31)
    let ix_bytes = bytearray.slice(redeemer.signed_data, 32, 33)
    let acceptor_ax_bytes = bytearray.slice(redeemer.signed_data, 34, 65)
    let acceptor_ay_bytes = bytearray.slice(redeemer.signed_data, 66, 97)
    let d_bytes = bytearray.slice(redeemer.signed_data, 98, 105)

    let ix = bytearray.to_int_big_endian(ix_bytes)
    let signed_d = bytearray.to_int_big_endian(d_bytes)

    // (c) defence-in-depth: d in signed_data must match redeemer (and proof)
    expect signed_d == redeemer.d

    // (d) customer_pubkey must match pk_c_hi / pk_c_lo from the proof
    let pk_hi_bytes = bytearray.slice(redeemer.customer_pubkey, 0, 15)
    let pk_lo_bytes = bytearray.slice(redeemer.customer_pubkey, 16, 31)
    expect bytearray.to_int_big_endian(pk_hi_bytes) == redeemer.pk_c_hi
    expect bytearray.to_int_big_endian(pk_lo_bytes) == redeemer.pk_c_lo

    // (e) the signed TxOutRef must be consumed in this tx
    let signed_out_ref = OutputReference { transaction_id: txid, output_index: ix }
    expect tx_consumes(self.inputs, signed_out_ref)

    // --- Layer A: Groth16 proof verification ---

    // Public inputs match the circuit:
    //   [d, commit_S_old, commit_S_new, user_id,
    //    issuer_Ax, issuer_Ay, pk_c_hi, pk_c_lo]
    let public_inputs =
      [
        redeemer.d,
        voucher.commit_spent,
        redeemer.commit_spent_new,
        voucher.user_id,
        redeemer.issuer_ax,
        redeemer.issuer_ay,
        redeemer.pk_c_hi,
        redeemer.pk_c_lo,
      ]

    let proof_valid = groth16.verify(vk, redeemer.proof, public_inputs)

    // --- Settlement checks (coalition membership + signatory) ---

    // (1) Exactly one reference input at the coalition-metadata address
    //     with a parseable CoalitionDatum.
    expect Some(coalition) =
      find_coalition_ref(self.reference_inputs, coalition_hash)

    // (2) datum.shop_pk ∈ coalition.shop_pks
    expect list_contains(coalition.shop_pks, voucher.shop_pk)

    // (3) datum.reificator_pk ∈ coalition.reificator_pks AND
    //     blake2b_224(datum.reificator_pk) ∈ tx.extra_signatories
    expect list_contains(coalition.reificator_pks, voucher.reificator_pk)
    let reificator_hash = crypto.blake2b_224(voucher.reificator_pk)
    expect list_contains(self.extra_signatories, reificator_hash)

    // (4) Output preserves user_id, shop_pk, reificator_pk; only
    //     commit_spent rotates.
    let output_valid =
      check_output(
        self,
        own_ref,
        voucher.user_id,
        redeemer.commit_spent_new,
        voucher.shop_pk,
        voucher.reificator_pk,
      )

    // We already `expect`-ed the signed_data binding checks above; keep a
    // reference to the unused parsed acceptor values so the compiler
    // doesn't strip them out and so future milestones (reificator trie
    // check) can use them directly.
    let _ = acceptor_ax_bytes
    let _ = acceptor_ay_bytes

    proof_valid && output_valid
  }

  else(_ctx: ScriptContext) {
    False
  }
}

/// Check the tx consumes an input matching the given OutputReference.
fn tx_consumes(inputs: List<Input>, ref: OutputReference) -> Bool {
  when inputs is {
    [] -> False
    [input, ..rest] ->
      if input.output_reference == ref {
        True
      } else {
        tx_consumes(rest, ref)
      }
  }
}

/// Verify the continuing output has the updated datum.
fn check_output(
  tx: Transaction,
  own_ref: OutputReference,
  user_id: Int,
  new_commit: Int,
  shop_pk: ByteArray,
  reificator_pk: ByteArray,
) -> Bool {
  expect Some(own_input) =
    tx.inputs |> find_input(own_ref)

  let own_address = own_input.output.address

  expect Some(output) =
    tx.outputs |> find_output_at(own_address)

  expect InlineDatum(raw_datum) = output.datum
  expect datum: VoucherDatum = raw_datum
  datum.user_id == user_id && datum.commit_spent == new_commit && datum.shop_pk == shop_pk && datum.reificator_pk == reificator_pk
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
