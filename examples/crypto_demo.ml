(* Demonstrates the Crypto stdlib wrappers backed by Solana hash syscalls. *)

external log_pubkey : bytes -> unit = "sol_log_pubkey"

let entrypoint input =
  let _ = Syscall.sol_log "crypto demo sha256" in
  let _ = log_pubkey (Crypto.sha256 input) in
  let _ = Syscall.sol_log "crypto demo keccak256" in
  let _ = log_pubkey (Crypto.keccak256 input) in
  0
