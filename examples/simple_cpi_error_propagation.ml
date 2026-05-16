(* Focused CPI fixture that routes through the generic invoke_signed staging
   path and returns the callee's non-success program error to the caller. *)

let error_program_id = Bytes.of_string "QQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQ"

let relay_account = Bytes.of_string "ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ"

let entrypoint _accounts _input =
  Cpi.invoke_signed
    {
      program_id = error_program_id;
      accounts =
        Array.of_list
          [ { pubkey = relay_account; is_writable = false; is_signer = false } ];
      data = Bytes.of_string "\x07\x00\xff\x0a";
    }
    (Array.of_list [])
