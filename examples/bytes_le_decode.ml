(* Decode a little-endian u32 from byte data using Bytes.get + bitwise ops.
   All inlined to avoid type inference issues.
   Returns 0 on success. *)

let entrypoint _ =
  let data = Bytes.of_string "\x02\x00\x00\x00\x01\x00\x00\x00" in
  let b0 = Char.code (Bytes.get data 0) in
  let b1 = Char.code (Bytes.get data 1) in
  let b2 = Char.code (Bytes.get data 2) in
  let b3 = Char.code (Bytes.get data 3) in
  let disc = b0 lor (b1 lsl 8) lor (b2 lsl 16) lor (b3 lsl 24) in
  let b4 = Char.code (Bytes.get data 4) in
  let b5 = Char.code (Bytes.get data 5) in
  let b6 = Char.code (Bytes.get data 6) in
  let b7 = Char.code (Bytes.get data 7) in
  let amount = b4 lor (b5 lsl 8) lor (b6 lsl 16) lor (b7 lsl 24) in
  (* disc = 2 (System Transfer), amount = 1 *)
  if disc = 2 && amount = 1 then 0 else 1
