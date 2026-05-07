(* Codegen golden fixture for the direct secp256k1 account-data write. *)

let set_account_data (account : account) bytes =
  let _ = account.data in
  let _ = bytes in
  ()

let recover_into_account (acc : account) h k s =
  let r = Crypto.secp256k1_recover h k s in
  let _ = set_account_data acc r in
  0

let entrypoint input =
  let _ = input in
  0
