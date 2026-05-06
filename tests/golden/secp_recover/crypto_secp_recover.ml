(* Codegen golden fixture for Crypto.secp256k1_recover. *)

let entrypoint input =
  let recovered = Crypto.secp256k1_recover input 1 input in
  let _ = recovered in
  0
