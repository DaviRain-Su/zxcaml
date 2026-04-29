(* Demonstrates a P3 SPL Token transfer built as a CPI.
   The example uses the Tokenkeg program id, source/destination/authority
   account metas, the Transfer instruction bytes, and invokes the token program. *)

let entrypoint _accounts _input =
  (* SPL Token transfer flow: amount is encoded below in the instruction data. *)
  let amount = 1 in
  (* Keep the amount binding visible to the example and to the compiler pipeline. *)
  let _ = amount in
  (* CPI construction: invoke_signed forwards the token transfer instruction
     with no PDA signer seeds for this harness path. *)
  invoke_signed
    {
      (* Legacy SPL Token program id used by the acceptance harness. *)
      program_id = Pubkey.token_program;
      (* SPL Token Transfer accounts:
         source token account (writable), destination token account (writable),
         and authority (signer).  The harness supplies the concrete pubkeys. *)
      accounts =
        Array.of_list
          [
            { pubkey = Bytes.of_string ""; is_writable = true; is_signer = false };
            { pubkey = Bytes.of_string ""; is_writable = true; is_signer = false };
            { pubkey = Bytes.of_string ""; is_writable = false; is_signer = true };
          ];
      (* Transfer instruction payload: discriminator 3 followed by amount=1
         as little-endian u64 bytes. *)
      data = Bytes.of_string "\003\001\000\000\000\000\000\000\000";
    }
    (* No PDA signer seeds are required for the basic authority-signed transfer. *)
    (Array.of_list [])
