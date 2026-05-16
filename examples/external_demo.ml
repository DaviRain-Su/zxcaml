(* Demonstrates custom OCaml names bound directly to Zig runtime symbols with
   external declarations. *)

let entrypoint _ =
  let remaining = Syscall.sol_remaining_compute_units () in
  let _ = Syscall.sol_log "external demo" in
  let _ = Syscall.sol_log_64 7 remaining 0 0 0 in
  0
