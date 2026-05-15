(* Exercises the public sol_log_64 surface with exact edge-case bit patterns.
   `max_int`, `min_int`, and `-1` cover the signed 64-bit boundaries that the
   runtime forwards to Solana with exact i64->u64 bit preservation. *)

let entrypoint _instruction_data =
  let _ = Syscall.sol_log "log64 boundaries" in
  let _ = Syscall.sol_log_64 0 1 max_int min_int (-1) in
  0
