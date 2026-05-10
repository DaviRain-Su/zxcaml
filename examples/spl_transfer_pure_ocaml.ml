(* Pure OCaml SPL Token Transfer — same as spl_token_transfer.ml
   but with instruction data constructed via Bytes.create + Bytes.set
   instead of Bytes.of_string with escape sequences.

   Encodes: discriminator=3, amount=1 as LE u64 = 9 bytes.
   Returns 0 on success. *)

let entrypoint _accounts _input =
  (* Build SPL Token Transfer instruction data in pure OCaml *)
  let amount = 1 in
  let data = Bytes.create 9 in
  (* Transfer discriminator = 3 *)
  let _ = Bytes.set data 0 (Char.chr 3) in
  (* amount = 1, little-endian u64 *)
  let _ = Bytes.set data 1 (Char.chr (amount land 0xFF)) in
  let _ = Bytes.set data 2 (Char.chr ((amount lsr 8) land 0xFF)) in
  let _ = Bytes.set data 3 (Char.chr ((amount lsr 16) land 0xFF)) in
  let _ = Bytes.set data 4 (Char.chr ((amount lsr 24) land 0xFF)) in
  let _ = Bytes.fill data 5 4 (Char.chr 0) in
  (* Verify: read back with Bytes.get + bitwise ops *)
  let disc = Char.code (Bytes.get data 0) in
  let b0 = Char.code (Bytes.get data 1) in
  let b1 = Char.code (Bytes.get data 2) in
  let decoded = b0 lor (b1 lsl 8) in
  if disc = 3 && decoded = 1 then 0 else 1
