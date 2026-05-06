(* hash-demo: BLAKE3 instruction-data digest writer. *)

external log_message : string -> unit = "sol_log_"

let set_account_data (account : account) bytes =
  (* Type witness for ZxCaml lowering; codegen emits the real account data
     write, copying the 32-byte digest into the writable output account. *)
  let _ = account.data in
  let _ = bytes in
  ()

let entrypoint output_account instruction_data =
  let _ = output_account.key in
  let _ = log_message "blake3 demo: hashing instruction data" in
  let digest = Crypto.blake3 instruction_data in
  let _ = set_account_data output_account digest in
  0
