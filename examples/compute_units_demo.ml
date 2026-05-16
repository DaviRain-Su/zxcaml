(* syscall-demo: remaining compute units before/after a known syscall. *)

let entrypoint _instruction_data =
  let before = Syscall.sol_remaining_compute_units () in
  let _ = Syscall.sol_log "compute units demo" in
  let after = Syscall.sol_remaining_compute_units () in
  let _ = Syscall.sol_log_64 before after 0 0 0 in
  0
