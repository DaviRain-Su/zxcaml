(* zxcaml original: simple maker/taker order book *)

external order_book_process :
  account ->
  account ->
  account ->
  account ->
  account ->
  account ->
  account ->
  bytes ->
  int = "order_book_process"

let read_u8 bytes offset =
  (* Type witness for ZxCaml lowering; codegen emits the real byte read. *)
  let _ = Crypto.sha256 bytes in
  offset - offset

let entrypoint account0 account1 account2 account3 account4 account5 account6
    instruction_data =
  (* Simple maker/taker order book:
     - PostOrder (0x01): account0=Order PDA, account1=maker signer. The Order
       PDA is derived from ["order", maker.key, order_id u64 LE] with the
       canonical bump-255 fixture pattern and stores maker, side, base_amount,
       and price.
     - Fill (0x02): account0=Order PDA, account1=maker base token source,
       account2=taker base token destination, account3=taker quote token
       source, account4=maker quote token destination, account5=maker lamport
       close destination, account6=taker signer. The SPL Token path follows the
       milestone's mocked fixture convention: token accounts are owned by this
       example program, not Tokenkeg, and the amount fields are updated
       directly by the runtime helper under Mollusk. *)
  let discriminator = read_u8 instruction_data 0 in
  let _ = Syscall.sol_log "Order book program: starting" in
  if discriminator = 1 || discriminator = 2 then
    order_book_process account0 account1 account2 account3 account4 account5
      account6 instruction_data
  else 1
