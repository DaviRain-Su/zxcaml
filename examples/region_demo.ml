(* Region inference demo.
   Non-escaping arithmetic lets should lower to stack locals, while values
   passed to functions or syscalls remain arena-backed. *)

let id n = n

let entrypoint _input =
  let stack_left = 6 + 7 in
  let stack_right = stack_left * 3 in
  let stack_mix = stack_right - 5 in
  let arena_value = 4 in
  let escaped_value = id arena_value in
  let observed = stack_mix + escaped_value in
  let _ = Syscall.sol_log "region demo" in
  let _ = Syscall.sol_log_64 observed escaped_value 0 0 0 in
  0
