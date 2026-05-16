(* zignocchio: examples/transfer-sol/lib.zig *)

let transfer_sol from_account to_account system_program instruction_data =
  (* Type witnesses for ZxCaml lowering; codegen emits the actual guarded
     System Program CPI using the zignocchio-compatible u64 amount payload. *)
  let _ = from_account.key in
  let _ = to_account.key in
  let _ = system_program.key in
  let _ = instruction_data in
  0

let entrypoint from_account to_account system_program instruction_data =
  let _ = Syscall.sol_log "transfer-sol: starting" in
  transfer_sol from_account to_account system_program instruction_data
