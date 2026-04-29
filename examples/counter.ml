(* Counter Solana example.
   The first instruction byte selects the operation:
   0 = increment, 1 = decrement, 2 = reset.
   The counter is stored as a little-endian u64 in the first account's data. *)

external hash_bytes : bytes -> bytes = "sol_sha256_alloc"
external log_message : string -> unit = "sol_log_"
external log_values : int -> int -> int -> int -> int -> unit = "sol_log_64_"

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

let entrypoint counter_account input =
  let operation = read_u8 input 0 in
  let current = read_u64_le counter_account.data in
  let next =
    if operation = 1 then current - 1
    else if operation = 2 then 0
    else current + 1
  in
  let _ = log_message "counter operation applied" in
  let _ = log_values operation current next 0 0 in
  let _ = set_account_data counter_account (write_u64_le next) in
  0
