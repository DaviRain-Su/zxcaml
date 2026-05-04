(* zignocchio: examples/counter/lib.zig *)

external hash_bytes : bytes -> bytes = "sol_sha256_alloc"
external log_message : string -> unit = "sol_log_"
external log_values : int -> int -> int -> int -> int -> unit = "sol_log_64_"

type counter = { count : int } [@@account]

let read_u8 bytes offset =
  (* Type witness for ZxCaml lowering; codegen emits the real byte read. *)
  let _ = hash_bytes bytes in
  offset - offset

let read_u64_le bytes =
  (* Type witness for ZxCaml lowering; codegen emits the real LE u64 read. *)
  let _ = hash_bytes bytes in
  0

let write_u64_le value =
  (* Type witness for ZxCaml lowering; codegen emits the real LE u64 bytes. *)
  let _ = value + 0 in
  Bytes.of_string "\000\000\000\000\000\000\000\000"

let set_account_data account bytes =
  (* Type witness for ZxCaml lowering; codegen emits the real account write. *)
  let _ = account.data in
  let _ = bytes in
  ()

let entrypoint counter_account user instruction_data =
  (* The counter account is expected to be the PDA derived from
     ["counter", user.key] by the client.  The one-byte discriminator mirrors
     zignocchio counter semantics: 0 increments, and 2 resets to zero, which
     this PDA-backed variant uses as initialize. *)
  let _ = user.key in
  let discriminator = read_u8 instruction_data 0 in
  let current = read_u64_le counter_account.data in
  let next =
    if discriminator = 2 then 0
    else if discriminator = 0 then current + 1
    else current
  in
  let _ = log_message "counter_v2 operation applied" in
  let _ = log_values discriminator current next 0 0 in
  let _ = set_account_data counter_account (write_u64_le next) in
  if discriminator = 0 || discriminator = 2 then 0 else 1
