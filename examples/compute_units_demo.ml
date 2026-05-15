(* syscall-demo: remaining compute units before/after a known syscall. *)

external emit_values : int -> int -> int -> int -> int -> unit = "sol_log_64_"

let entrypoint _instruction_data =
  let before = Syscall.sol_remaining_compute_units () in
  let _ = Syscall.sol_log "compute units demo" in
  let after = Syscall.sol_remaining_compute_units () in
  let _ = emit_values before after 0 0 0 in
  0
