(* Encode an SPL Token Transfer instruction data buffer in pure OCaml.
   discriminator=3 (1 byte), amount=1 (8 bytes LE) = 9 bytes total.
   Returns 0 on success. *)

let entrypoint _ =
  let buf = Bytes.create 9 in
  (* Transfer discriminator = 3 *)
  let _ = Bytes.set buf 0 (Char.chr 3) in
  (* amount = 1, little-endian *)
  let _ = Bytes.set buf 1 (Char.chr 1) in
  let _ = Bytes.set buf 2 (Char.chr 0) in
  let _ = Bytes.set buf 3 (Char.chr 0) in
  let _ = Bytes.set buf 4 (Char.chr 0) in
  let _ = Bytes.set buf 5 (Char.chr 0) in
  let _ = Bytes.set buf 6 (Char.chr 0) in
  let _ = Bytes.set buf 7 (Char.chr 0) in
  let _ = Bytes.set buf 8 (Char.chr 0) in
  (* Verify *)
  let disc = Char.code (Bytes.get buf 0) in
  let lo = Char.code (Bytes.get buf 1) in
  let hi = Char.code (Bytes.get buf 2) in
  let len = Bytes.length buf in
  if disc = 3 && lo = 1 && hi = 0 && len = 9 then 0 else 1
