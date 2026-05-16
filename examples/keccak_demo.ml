(* hash-demo: Keccak-256 instruction-data digest writer. *)

let set_account_data (account : account) bytes =
  (* Type witness for ZxCaml lowering; codegen emits the real account data
     write, copying the 32-byte digest into the writable output account. *)
  let _ = account.data in
  let _ = bytes in
  ()

let entrypoint output_account instruction_data =
  let _ = output_account.key in
  let _ = Syscall.sol_log "keccak demo: hashing instruction data" in
  let digest = Crypto.keccak256 instruction_data in
  let _ = set_account_data output_account digest in
  0
