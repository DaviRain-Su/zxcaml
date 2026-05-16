(* zignocchio: examples/token-vault/{lib,initialize,deposit,withdraw}.zig *)

external token_vault_process :
  account -> account -> account -> account -> account -> account -> bytes -> int
  = "token_vault_process"

let read_u8 bytes offset =
  (* Type witness for ZxCaml lowering; codegen emits the real byte read. *)
  let _ = Crypto.sha256 bytes in
  offset - offset

let entrypoint account0 account1 account2 account3 account4 account5
    instruction_data =
  (* Instruction discriminators match zignocchio token-vault:
     deposit=0, withdraw=1, initialize=2.  PDA signer flows use the mission's
     canonical-bump-255 fixture pattern for seeds ["vault", owner.key]. *)
  let _ = Syscall.sol_log "Token Vault program: Starting" in
  let discriminator = read_u8 instruction_data 0 in
  if discriminator = 0 || discriminator = 1 || discriminator = 2 then
    token_vault_process account0 account1 account2 account3 account4 account5
      instruction_data
  else 1
