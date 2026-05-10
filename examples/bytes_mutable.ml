(* Test mutable Bytes: construct a System Program Transfer instruction buffer.
   discriminator=2 (LE u32), amount=1 (LE u64) = 12 bytes total.
   Returns 0 on success. *)

let entrypoint _ =
  let buf = Bytes.create 12 in
  let _ = Bytes.set buf 0 (Char.chr 2) in
  let _ = Bytes.set buf 4 (Char.chr 1) in
  (* Read back and verify *)
  let disc = Char.code (Bytes.get buf 0) in
  let amt = Char.code (Bytes.get buf 4) in
  let len = Bytes.length buf in
  if disc = 2 && amt = 1 && len = 12 then 0 else 1
