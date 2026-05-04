(* zignocchio: examples/vault/{lib,deposit,withdraw}.zig *)

external hash_bytes : bytes -> bytes = "sol_sha256_alloc"
external log_message : string -> unit = "sol_log_"
external vault_v2_deposit : account -> account -> account -> bytes -> int
  = "vault_v2_deposit"

external vault_v2_withdraw : account -> account -> account -> bytes -> int
  = "vault_v2_withdraw"

let read_u8 bytes offset =
  (* Type witness for ZxCaml lowering; codegen emits the real byte read. *)
  let _ = hash_bytes bytes in
  offset - offset

let entrypoint owner vault system_program instruction_data =
  let _ = log_message "Vault program: Starting" in
  let discriminator = read_u8 instruction_data 0 in
  if discriminator = 0 then vault_v2_deposit owner vault system_program instruction_data
  else if discriminator = 1 then vault_v2_withdraw owner vault system_program instruction_data
  else 1
