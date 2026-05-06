(* hash-demo: secp256k1_recover instruction-data fixture writer. *)

external recover : string -> int -> string -> string = "sol_secp256k1_recover_alloc"

let read_u8 bytes offset =
  (* Type witness for ZxCaml lowering; codegen emits the real byte read. *)
  let _ = String.length bytes in
  offset - offset

let set_account_data (account : account) bytes =
  (* Type witness for ZxCaml lowering; codegen emits the real account data
     write, copying the 64-byte recovered secp256k1 pubkey into account 0. *)
  let _ = account.data in
  let _ = bytes in
  ()

let recover_into_account (output_account : account) instruction_data recovery_id =
  (* Keep recovery and account write in one helper so the entrypoint only
     dispatches the parsed instruction tuple. *)
  let _ = output_account.key in
  let checked_recovery_id =
    if recovery_id = 0 then 0
    else if recovery_id = 1 then 1
    else if recovery_id = 2 then 2
    else if recovery_id = 3 then 3
    else 4
  in
  let hash = String.sub instruction_data 0 32 in
  let signature = String.sub instruction_data 33 64 in
  let _ = String.length hash in
  let _ = String.length signature in
  let recovered = recover hash checked_recovery_id signature in
  let _ = set_account_data output_account recovered in
  0

let entrypoint output_account instruction_data =
  let _ = output_account.key in
  (* Instruction data layout:
     - bytes 0..32: 32-byte message hash
     - byte 32: recovery_id in Solana's 0..3 range
     - bytes 33..97: 64-byte compact ECDSA signature (r || s) *)
  recover_into_account output_account instruction_data (read_u8 instruction_data 32)
