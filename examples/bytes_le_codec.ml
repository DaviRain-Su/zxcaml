(* Comprehensive test: encode + decode a little-endian u32 using
   Bytes.create, Bytes.set, Bytes.get, and bitwise operations.
   All inlined to avoid type inference issues with user-defined functions.
   Returns 0 on success. *)

let entrypoint _ =
  let buf = Bytes.create 8 in
  (* Write u32 LE 42 at offset 0 *)
  let _ = Bytes.set buf 0 (Char.chr (42 land 0xFF)) in
  let _ = Bytes.set buf 1 (Char.chr ((42 lsr 8) land 0xFF)) in
  let _ = Bytes.set buf 2 (Char.chr ((42 lsr 16) land 0xFF)) in
  let _ = Bytes.set buf 3 (Char.chr ((42 lsr 24) land 0xFF)) in
  (* Write u32 LE 1000 at offset 4 *)
  let _ = Bytes.set buf 4 (Char.chr (1000 land 0xFF)) in
  let _ = Bytes.set buf 5 (Char.chr ((1000 lsr 8) land 0xFF)) in
  let _ = Bytes.set buf 6 (Char.chr ((1000 lsr 16) land 0xFF)) in
  let _ = Bytes.set buf 7 (Char.chr ((1000 lsr 24) land 0xFF)) in
  (* Read back *)
  let b0 = Char.code (Bytes.get buf 0) in
  let b1 = Char.code (Bytes.get buf 1) in
  let b2 = Char.code (Bytes.get buf 2) in
  let b3 = Char.code (Bytes.get buf 3) in
  let a = b0 lor (b1 lsl 8) lor (b2 lsl 16) lor (b3 lsl 24) in
  let b4 = Char.code (Bytes.get buf 4) in
  let b5 = Char.code (Bytes.get buf 5) in
  let b6 = Char.code (Bytes.get buf 6) in
  let b7 = Char.code (Bytes.get buf 7) in
  let b = b4 lor (b5 lsl 8) lor (b6 lsl 16) lor (b7 lsl 24) in
  if a = 42 && b = 1000 then 0 else 1
