(* R13 Solana product-surface polish: account guard helpers.

   The example returns explicit custom status codes instead of panicking, which
   mirrors common Solana account-validation flow before state mutation.
   Error constants use the `error_` prefix so `omlz idl` emits them. *)

let error_missing_signer = 1

let error_missing_writable = 2

let error_wrong_owner = 3

let entrypoint authority guarded_account instruction_data =
  let _ = instruction_data in
  if not (Account.is_signer authority) then error_missing_signer
  else if not (Account.is_writable guarded_account) then error_missing_writable
  else if not (Account.is_owned_by guarded_account (Account.key authority)) then error_wrong_owner
  else 0
