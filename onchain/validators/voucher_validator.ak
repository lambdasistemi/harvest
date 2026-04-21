use aiken/builtin
use aiken/crypto
use aiken/primitive/bytearray
use cardano/address.{Address, Script}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{InlineDatum, Input, Output, OutputReference, Transaction}
use harvest/coalition_types.{CoalitionDatum}
use voucher/groth16
use voucher/types.{Groth16Proof, VoucherAction, VoucherDatum, VerificationKey}

/// Unified voucher validator.
///
/// One script, one address. The `VoucherAction` redeemer selects the
/// operation:
///   - **Spend**: Groth16 proof + Ed25519 two-layer authorisation.
///   - **Redeem**: reificator destroys the entry.
///   - **Revert**: shop master rolls back or removes an entry.
validator voucher_validator(vk: VerificationKey, coalition_hash: ByteArray) {
  spend(
    datum: Option<VoucherDatum>,
    redeemer: VoucherAction,
    own_ref: OutputReference,
    self: Transaction,
  ) {
    expect Some(voucher) = datum

    when redeemer is {
      VoucherAction.Spend {
        d,
        commit_spent_new,
        issuer_ax,
        issuer_ay,
        pk_c_hi,
        pk_c_lo,
        customer_pubkey,
        customer_signature,
        signed_data,
        proof,
      } ->
        handle_spend(
          voucher,
          d,
          commit_spent_new,
          issuer_ax,
          issuer_ay,
          pk_c_hi,
          pk_c_lo,
          customer_pubkey,
          customer_signature,
          signed_data,
          proof,
          own_ref,
          self,
          vk,
          coalition_hash,
        )
      VoucherAction.Redeem { reificator_sig } ->
        handle_redeem(
          voucher,
          reificator_sig,
          own_ref,
          self,
          coalition_hash,
        )
      VoucherAction.Revert { prior_commit_spent, shop_sig } ->
        handle_revert(
          voucher,
          prior_commit_spent,
          shop_sig,
          own_ref,
          self,
          coalition_hash,
        )
    }
  }

  else(_ctx: ScriptContext) {
    False
  }
}

// ─── Spend ───────────────────────────────────────────────────────────

fn handle_spend(
  voucher: VoucherDatum,
  d: Int,
  commit_spent_new: Int,
  issuer_ax: Int,
  issuer_ay: Int,
  pk_c_hi: Int,
  pk_c_lo: Int,
  customer_pubkey: ByteArray,
  customer_signature: ByteArray,
  signed_data: ByteArray,
  proof: Groth16Proof,
  own_ref: OutputReference,
  self: Transaction,
  vk: VerificationKey,
  coalition_hash: ByteArray,
) -> Bool {
  // --- Layer B: Ed25519 signature + canonical signed_data parse ---

  // (a) verify the customer's Ed25519 signature
  expect
    crypto.verify_ed25519_signature(
      customer_pubkey,
      signed_data,
      customer_signature,
    )

  // (b) parse signed_data (106-byte layout, see VoucherAction.Spend doc)
  let txid = bytearray.slice(signed_data, 0, 31)
  let ix_bytes = bytearray.slice(signed_data, 32, 33)
  let acceptor_ax_bytes = bytearray.slice(signed_data, 34, 65)
  let acceptor_ay_bytes = bytearray.slice(signed_data, 66, 97)
  let d_bytes = bytearray.slice(signed_data, 98, 105)

  let ix = bytearray.to_int_big_endian(ix_bytes)
  let signed_d = bytearray.to_int_big_endian(d_bytes)

  // (c) defence-in-depth: d in signed_data must match redeemer (and proof)
  expect signed_d == d

  // (d) customer_pubkey must match pk_c_hi / pk_c_lo from the proof
  let pk_hi_bytes = bytearray.slice(customer_pubkey, 0, 15)
  let pk_lo_bytes = bytearray.slice(customer_pubkey, 16, 31)
  expect bytearray.to_int_big_endian(pk_hi_bytes) == pk_c_hi
  expect bytearray.to_int_big_endian(pk_lo_bytes) == pk_c_lo

  // (e) the signed TxOutRef must be consumed in this tx
  let signed_out_ref = OutputReference { transaction_id: txid, output_index: ix }
  expect tx_consumes(self.inputs, signed_out_ref)

  // --- Layer A: Groth16 proof verification ---

  let public_inputs =
    [d, voucher.commit_spent, commit_spent_new, voucher.user_id, issuer_ax, issuer_ay, pk_c_hi, pk_c_lo]

  let proof_valid = groth16.verify(vk, proof, public_inputs)

  // --- Settlement checks (coalition membership + signatory) ---

  expect Some(coalition) =
    find_coalition_ref(self.reference_inputs, coalition_hash)

  expect list_contains(coalition.shop_pks, voucher.shop_pk)

  expect list_contains(coalition.reificator_pks, voucher.reificator_pk)
  let reificator_hash = crypto.blake2b_224(voucher.reificator_pk)
  expect list_contains(self.extra_signatories, reificator_hash)

  let output_valid =
    check_spend_output(
      self,
      own_ref,
      voucher.user_id,
      commit_spent_new,
      voucher.shop_pk,
      voucher.reificator_pk,
    )

  // Keep a reference to the unused parsed acceptor values so the
  // compiler doesn't strip them.
  let _ = acceptor_ax_bytes
  let _ = acceptor_ay_bytes

  proof_valid && output_valid
}

// ─── Redeem ──────────────────────────────────────────────────────────

fn handle_redeem(
  voucher: VoucherDatum,
  reificator_sig: ByteArray,
  own_ref: OutputReference,
  self: Transaction,
  coalition_hash: ByteArray,
) -> Bool {
  // (1) Coalition reference input present; parseable
  expect Some(coalition) =
    find_coalition_ref(self.reference_inputs, coalition_hash)

  // (2) datum.reificator_pk ∈ coalition.reificator_pks
  expect list_contains(coalition.reificator_pks, voucher.reificator_pk)

  // (3) blake2b_224(datum.reificator_pk) ∈ tx.extra_signatories
  let reificator_hash = crypto.blake2b_224(voucher.reificator_pk)
  expect list_contains(self.extra_signatories, reificator_hash)

  // (4) Ed25519 sig over (txid || "REDEEM")
  let message =
    bytearray.concat(own_ref.transaction_id, "REDEEM")
  expect
    crypto.verify_ed25519_signature(
      voucher.reificator_pk,
      message,
      reificator_sig,
    )

  // (5) No output at this address with this user_id
  expect Some(own_input) =
    find_input(self.inputs, own_ref)
  let own_address = own_input.output.address
  no_voucher_output_at(self.outputs, own_address, voucher.user_id)
}

// ─── Revert ──────────────────────────────────────────────────────────

fn handle_revert(
  voucher: VoucherDatum,
  prior_commit_spent: Int,
  shop_sig: ByteArray,
  own_ref: OutputReference,
  self: Transaction,
  coalition_hash: ByteArray,
) -> Bool {
  // (1) Coalition reference input present; parseable
  expect Some(coalition) =
    find_coalition_ref(self.reference_inputs, coalition_hash)

  // (2) datum.shop_pk ∈ coalition.shop_pks
  expect list_contains(coalition.shop_pks, voucher.shop_pk)

  // (3) blake2b_224(datum.shop_pk) ∈ tx.extra_signatories
  let shop_hash = crypto.blake2b_224(voucher.shop_pk)
  expect list_contains(self.extra_signatories, shop_hash)

  // (4) Ed25519 sig over (txid || "REVERT" || prior_bytes)
  let prior_bytes =
    builtin.integer_to_bytearray(True, 32, prior_commit_spent)
  let message =
    own_ref.transaction_id
      |> bytearray.concat("REVERT")
      |> bytearray.concat(prior_bytes)
  expect
    crypto.verify_ed25519_signature(
      voucher.shop_pk,
      message,
      shop_sig,
    )

  // (5) Either full removal or valid rollback output
  expect Some(own_input) =
    find_input(self.inputs, own_ref)
  let own_address = own_input.output.address
  check_revert_output(
    self.outputs,
    own_address,
    voucher.user_id,
    voucher.shop_pk,
    voucher.reificator_pk,
    prior_commit_spent,
  )
}

// ─── Shared helpers ──────────────────────────────────────────────────

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

fn check_spend_output(
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

/// Verify no output at the given address carries a VoucherDatum with
/// the specified user_id.
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

/// Validate the revert output branch:
///   - 0 outputs at this address with matching user_id: full removal
///   - 1 output with matching user_id AND same shop_pk, reificator_pk,
///     and commit_spent == prior_commit_spent: rollback
///   - Otherwise: fail
fn check_revert_output(
  outputs: List<Output>,
  addr: Address,
  user_id: Int,
  shop_pk: ByteArray,
  reificator_pk: ByteArray,
  prior_commit_spent: Int,
) -> Bool {
  count_and_validate_revert_outputs(
    outputs,
    addr,
    user_id,
    shop_pk,
    reificator_pk,
    prior_commit_spent,
    0,
  )
}

fn count_and_validate_revert_outputs(
  outputs: List<Output>,
  addr: Address,
  user_id: Int,
  shop_pk: ByteArray,
  reificator_pk: ByteArray,
  prior_commit_spent: Int,
  found: Int,
) -> Bool {
  when outputs is {
    [] -> found <= 1
    [output, ..rest] ->
      if output.address == addr {
        when output.datum is {
          InlineDatum(raw) -> {
            let pair = builtin.un_constr_data(raw)
            let tag = builtin.fst_pair(pair)
            if tag == 0 {
              let fields = builtin.snd_pair(pair)
              when fields is {
                [uid_data, cs_data, spk_data, rpk_data, ..] -> {
                  let uid = builtin.un_i_data(uid_data)
                  if uid == user_id {
                    let cs = builtin.un_i_data(cs_data)
                    let spk = builtin.un_b_data(spk_data)
                    let rpk = builtin.un_b_data(rpk_data)
                    if
                    cs == prior_commit_spent && spk == shop_pk && rpk == reificator_pk{

                      count_and_validate_revert_outputs(
                        rest,
                        addr,
                        user_id,
                        shop_pk,
                        reificator_pk,
                        prior_commit_spent,
                        found + 1,
                      )
                    } else {
                      False
                    }
                  } else {
                    count_and_validate_revert_outputs(
                      rest,
                      addr,
                      user_id,
                      shop_pk,
                      reificator_pk,
                      prior_commit_spent,
                      found,
                    )
                  }
                }
                _ ->
                  count_and_validate_revert_outputs(
                    rest,
                    addr,
                    user_id,
                    shop_pk,
                    reificator_pk,
                    prior_commit_spent,
                    found,
                  )
              }
            } else {
              count_and_validate_revert_outputs(
                rest,
                addr,
                user_id,
                shop_pk,
                reificator_pk,
                prior_commit_spent,
                found,
              )
            }
          }
          _ ->
            count_and_validate_revert_outputs(
              rest,
              addr,
              user_id,
              shop_pk,
              reificator_pk,
              prior_commit_spent,
              found,
            )
        }
      } else {
        count_and_validate_revert_outputs(
          rest,
          addr,
          user_id,
          shop_pk,
          reificator_pk,
          prior_commit_spent,
          found,
        )
      }
  }
}
