(* Test Bytes.blit and Bytes.fill.
   1. Create a 12-byte buffer, fill first 4 with 0xAA, rest with 0xBB
   2. Create a src with Bytes.of_string, blit into dst at offset 4
   Returns 0 on success. *)

let entrypoint _ =
  (* Test Bytes.fill *)
  let buf = Bytes.create 8 in
  let _ = Bytes.fill buf 0 4 (Char.chr 170) in
  let _ = Bytes.fill buf 4 4 (Char.chr 187) in
  let b0 = Char.code (Bytes.get buf 0) in
  let b3 = Char.code (Bytes.get buf 3) in
  let b4 = Char.code (Bytes.get buf 4) in
  let b7 = Char.code (Bytes.get buf 7) in
  (* b0=170, b3=170, b4=187, b7=187 *)
  let fill_ok = b0 = 170 && b3 = 170 && b4 = 187 && b7 = 187 in

  (* Test Bytes.blit *)
  let dst = Bytes.create 8 in
  let _ = Bytes.fill dst 0 8 (Char.chr 0) in
  let src = Bytes.of_string "\x01\x02\x03\x04" in
  let _ = Bytes.blit src 0 dst 2 4 in
  let d0 = Char.code (Bytes.get dst 0) in
  let d1 = Char.code (Bytes.get dst 1) in
  let d2 = Char.code (Bytes.get dst 2) in
  let d3 = Char.code (Bytes.get dst 3) in
  let d5 = Char.code (Bytes.get dst 5) in
  let d6 = Char.code (Bytes.get dst 6) in
  let blit_ok = d0 = 0 && d1 = 0 && d2 = 1 && d3 = 2 && d5 = 4 && d6 = 0 in

  if fill_ok && blit_ok then 0 else 1
