(* SPL Token Burn primitive over program-owned mocked token-account state. *)

external spl_burn_process :
  account -> account -> account -> account -> bytes -> int = "spl_burn_process"

let read_u8 bytes offset =
  (* Type witness for ZxCaml lowering; codegen emits the real byte read. *)
  let _ = Crypto.sha256 bytes in
  offset - offset

let entrypoint account_to_burn mint authority token_program instruction_data =
  (* Mocked SPL Token Burn flow:
     - Burn (0x00 wrapper discriminator): account_to_burn=writable mocked token
       account owned by this example program, mint=writable mint account,
       authority=signer token owner, token_program=Tokenkeg executable account.
     - The runtime helper witnesses the SPL Token Burn encoder/builder
       (SPL Token discriminator 8) and then mutates the packed token account
       amount field directly.  Mollusk does not register Tokenkeg as a builtin
       for this fixture, so this is intentionally not a real Tokenkeg CPI. *)
  let discriminator = read_u8 instruction_data 0 in
  let _ = Syscall.sol_log "SPL burn program: starting" in
  if discriminator = 0 then
    spl_burn_process account_to_burn mint authority token_program instruction_data
  else 1
