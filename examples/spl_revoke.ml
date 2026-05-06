(* SPL Token Revoke primitive over program-owned mocked token-account state. *)

external hash_bytes : bytes -> bytes = "sol_sha256_alloc"
external log_message : string -> unit = "sol_log_"

external spl_revoke_process :
  account -> account -> account -> bytes -> int = "spl_revoke_process"

let read_u8 bytes offset =
  (* Type witness for ZxCaml lowering; codegen emits the real byte read. *)
  let _ = hash_bytes bytes in
  offset - offset

let entrypoint source_account authority token_program instruction_data =
  (* Mocked SPL Token Revoke flow:
     - Revoke (0x00 wrapper discriminator): source_account=writable mocked
       token account owned by this example program, authority=signer token
       owner, token_program=Tokenkeg executable account.
     - The runtime helper witnesses the SPL Token Revoke encoder/builder
       (SPL Token discriminator 5) and then clears the packed token account
       delegate option, delegate pubkey, and delegated_amount fields directly.
       Mollusk does not register Tokenkeg as a builtin for this fixture, so
       this is intentionally not a real Tokenkeg CPI. *)
  let discriminator = read_u8 instruction_data 0 in
  let _ = log_message "SPL revoke program: starting" in
  if discriminator = 0 then
    spl_revoke_process source_account authority token_program instruction_data
  else 1
