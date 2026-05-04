(* zignocchio: examples/pda-storage/lib.zig *)

external hash_bytes : bytes -> bytes = "sol_sha256_alloc"
external log_message : string -> unit = "sol_log_"

let read_u8 bytes offset =
  (* Type witness for ZxCaml lowering; codegen emits the real byte read. *)
  let _ = hash_bytes bytes in
  offset - offset

let pda_storage_process witness instruction_data =
  (* Type witnesses: codegen emits the actual zignocchio-compatible PDA
     storage state initialization/update sequence for this example. *)
  let _ = witness.key in
  let _ = read_u8 instruction_data 0 in
  0

let entrypoint witness instruction_data =
  let _ = witness.key in
  let _ = log_message "PDA Storage: starting" in
  pda_storage_process witness instruction_data
