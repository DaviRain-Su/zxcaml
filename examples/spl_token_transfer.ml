(* Demonstrates a P3 SPL Token transfer built as a CPI.
   The example uses the runtime-supplied token program and source/destination/
   authority accounts, then invokes the token program without PDA signer seeds. *)

let entrypoint _accounts _input =
  (* SPL Token transfer flow: amount is encoded below in the instruction data. *)
  let amount = 1 in
  (* Keep the amount binding visible to the example and to the compiler pipeline. *)
  let _ = amount in
  (* CPI construction: invoke forwards the authority's outer transaction
     signature to the token program; no PDA signer seeds are required. *)
  invoke
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
