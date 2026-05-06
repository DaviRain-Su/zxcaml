(* SPL Token CloseAccount primitive over program-owned mocked token-account state. *)

external hash_bytes : bytes -> bytes = "sol_sha256_alloc"
external log_message : string -> unit = "sol_log_"

external spl_close_account_process :
  account -> account -> account -> account -> bytes -> int = "spl_close_account_process"

let read_u8 bytes offset =
  (* Type witness for ZxCaml lowering; codegen emits the real byte read. *)
  let _ = hash_bytes bytes in
  offset - offset

let entrypoint account_to_close destination authority token_program instruction_data =
  (* Mocked SPL Token CloseAccount flow:
     - CloseAccount (0x00 wrapper discriminator): account_to_close=writable
       mocked token account owned by this example program, destination=writable
       rent recipient, authority=signer token owner, token_program=Tokenkeg
       executable account.
     - The runtime helper witnesses the SPL Token CloseAccount encoder/builder
       (SPL Token discriminator 9) and then transfers lamports plus zeroes the
       packed token account data directly.  Mollusk does not register Tokenkeg
       as a builtin for this fixture, so this is intentionally not a real
       Tokenkeg CPI. *)
  let discriminator = read_u8 instruction_data 0 in
  let _ = log_message "SPL close account program: starting" in
  if discriminator = 0 then
    spl_close_account_process account_to_close destination authority token_program instruction_data
  else 1
