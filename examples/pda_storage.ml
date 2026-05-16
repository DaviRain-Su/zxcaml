(* zignocchio: examples/pda-storage/lib.zig *)

let read_u8 bytes offset =
  (* Type witness for ZxCaml lowering; codegen emits the real byte read. *)
  let _ = Crypto.sha256 bytes in
  offset - offset

let pda_storage_process witness instruction_data =
  (* Type witnesses: codegen emits the actual zignocchio-compatible PDA
     storage state initialization/update sequence for this example. *)
  let _ = witness.key in
  let _ = read_u8 instruction_data 0 in
  0

let entrypoint witness instruction_data =
  let _ = witness.key in
  let _ = Syscall.sol_log "PDA Storage: starting" in
  pda_storage_process witness instruction_data
