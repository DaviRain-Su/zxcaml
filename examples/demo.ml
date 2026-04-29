(* ZxCaml Hackathon Demo
   Demonstrates: OCaml -> Solana BPF compiler
   Features shown: type inference and syscalls *)

let entrypoint _ =
  (* 1. Log via syscall *)
  let _ = Syscall.sol_log "ZxCaml demo" in
  let _ = Syscall.sol_log_64 42 0 0 0 0 in
  0
