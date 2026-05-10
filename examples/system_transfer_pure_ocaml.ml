(* Pure OCaml System Program Transfer — same as simple_cpi.ml data encoding
   but with instruction data constructed via Bytes.create + Bytes.set + bitwise.

   Encodes: discriminator=2 (u32 LE), amount=1 (u64 LE) = 12 bytes.
   Returns 0 on success. *)

let entrypoint _accounts _input =
  let amount = 1 in
  let data = Bytes.create 12 in
  (* System Transfer discriminator = 2, little-endian u32 *)
  let _ = Bytes.set data 0 (Char.chr 2) in
  let _ = Bytes.fill data 1 3 (Char.chr 0) in
  (* amount as u64 LE *)
  let _ = Bytes.set data 4 (Char.chr (amount land 0xFF)) in
  let _ = Bytes.set data 5 (Char.chr ((amount lsr 8) land 0xFF)) in
  let _ = Bytes.fill data 6 6 (Char.chr 0) in
  (* Verify round-trip *)
  let disc = Char.code (Bytes.get data 0) in
  let lo = Char.code (Bytes.get data 4) in
  let hi = Char.code (Bytes.get data 5) in
  let decoded = lo lor (hi lsl 8) in
  let len = Bytes.length data in
  if disc = 2 && decoded = 1 && len = 12 then 0 else 1
