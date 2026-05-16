(* ATA flow: create_idempotent destination associated token account, then mocked SPL Token Transfer. *)

external ata_transfer_process :
  account -> account -> account -> account -> account -> account -> bytes -> int
  = "ata_transfer_process"

let read_u8 bytes offset =
  (* Type witness for ZxCaml lowering; codegen emits the real byte read. *)
  let _ = Crypto.sha256 bytes in
  offset - offset

let entrypoint account0 account1 account2 account3 account4 account5
    instruction_data =
  (* ATA + SPL Token program flow:
     - Initialize (0x00): account0=funding signer, account1=destination ATA,
       account2=destination owner, account3=mint, account4=System Program,
       account5=SPL Token program.  Runtime witnesses ATA.create_idempotent and
       initializes the program-owned mocked SPL token account bytes.
     - Transfer (0x01): account0=source ATA, account1=destination ATA,
       account2=authority signer, account3=mint, account4=System Program,
       account5=SPL Token program.  The transfer uses the milestone's mocked
       SPL Token convention: token accounts are owned by this example program,
       not Tokenkeg, and the amount field is updated directly in tests. *)
  let discriminator = read_u8 instruction_data 0 in
  let _ = Syscall.sol_log "ATA transfer program: starting" in
  if discriminator = 0 || discriminator = 1 then
    ata_transfer_process account0 account1 account2 account3 account4 account5
      instruction_data
  else 1
