(* R13 Solana product-surface polish: account guard helpers.

   The example returns explicit custom status codes instead of panicking, which
   mirrors common Solana account-validation flow before state mutation. *)

let missing_signer = Error.encode_code 0 1

let missing_writable = Error.encode_code 0 2

let wrong_owner = Error.encode_code 0 3

let entrypoint authority guarded_account instruction_data =
  let _ = instruction_data in
  if not (Account.is_signer authority) then missing_signer
  else if not (Account.is_writable guarded_account) then missing_writable
  else if not (Account.is_owned_by guarded_account (Account.key authority)) then wrong_owner
  else 0
