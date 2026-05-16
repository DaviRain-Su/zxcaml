(* zignocchio: examples/logonly/lib.zig *)

let entrypoint _instruction_data =
  let _ = Syscall.sol_log "logonly: hello" in
  let _ = Syscall.sol_log_64 11 22 33 44 55 in
  let _ = Syscall.sol_log_compute_units () in
  0
