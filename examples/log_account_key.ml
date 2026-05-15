(* Logs an input account key through the public pubkey-logging surface. *)

let entrypoint logged_account instruction_data =
  let _ = instruction_data in
  let _ = Syscall.sol_log_pubkey (Account.key logged_account) in
  0
