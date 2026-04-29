(* Demonstrates P3 Solana syscall bindings from OCaml.
   The example hashes bytes, reads Clock and compute-unit sysvars, and writes
   log output through the runtime syscall dispatch table. *)

let entrypoint _ =
  (* Syscall usage: sol_sha256 exercises the hash syscall on a small payload. *)
  let _ = Syscall.sol_sha256 "zxcaml" in
  (* Sysvar reads expose Solana runtime state as ordinary OCaml record fields. *)
  let clock = Syscall.sol_get_clock_sysvar () in
  let remaining = Syscall.sol_remaining_compute_units () in
  (* sol_log emits a human-readable marker in the transaction log. *)
  let _ = Syscall.sol_log "syscall test" in
  (* sol_log_64 logs five integer values; here they summarize the sysvar reads. *)
  let _ =
    Syscall.sol_log_64 clock.slot clock.epoch clock.unix_timestamp remaining 0
  in
  (* Return zero so the harness treats the syscall smoke test as successful. *)
  0
