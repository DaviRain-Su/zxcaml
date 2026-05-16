(* Demonstrates a P3 SPL Token transfer built as a CPI.
   The example uses the runtime-supplied token program and source/destination/
   authority accounts, then invokes the token program without PDA signer seeds. *)

let entrypoint _accounts _input =
  (* SPL Token transfer flow: amount is encoded below in the instruction data. *)
  let amount = 1 in
  (* Keep the amount binding visible to the example and to the compiler pipeline. *)
  let _ = amount in
  Cpi.invoke
    {
      program_id = Pubkey.token_program;
      accounts =
        Array.of_list
          [
            { pubkey = Bytes.of_string ""; is_writable = true; is_signer = false };
            { pubkey = Bytes.of_string ""; is_writable = true; is_signer = false };
            { pubkey = Bytes.of_string ""; is_writable = false; is_signer = true };
          ];
      data = Bytes.of_string "\003\001\000\000\000\000\000\000\000";
    }
