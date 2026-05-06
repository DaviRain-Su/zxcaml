(* Demonstrates unit-test bindings over pubkey equality and seed-prefix helpers. *)

let rec string_eq_at left right index length =
  if index = length then true
  else if String.get left index = String.get right index then
    string_eq_at left right (index + 1) length
  else false

let pubkey_eq left right =
  if String.length left = String.length right then
    string_eq_at left right 0 (String.length left)
  else false

let seed_prefix_score seed =
  (Char.code (String.get seed 0) * 1000000)
  + (Char.code (String.get seed 1) * 10000)
  + (Char.code (String.get seed 2) * 100)
  + Char.code (String.get seed 3)

let system_program = "11111111111111111111111111111111"

let token_program = "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"

let vault_seed = "vault:alice:0001"

let%test_unit "pubkey eq distinguishes keys" =
  assert (
    if pubkey_eq system_program system_program then
      if pubkey_eq system_program token_program then false else true
    else false)

let%test_unit "seed prefix derivation" =
  assert (seed_prefix_score vault_seed = 118981808)
