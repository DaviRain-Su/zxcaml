(* Minimal lamport vault example inspired by zignocchio.
   Instruction data byte 0 routes the operation:
   0 = deposit, followed by an eight-byte little-endian amount.
   1 = withdraw all lamports from the vault PDA back to the owner.
   The vault PDA is derived from seeds ["vault", owner.key]. *)

external hash_bytes : bytes -> bytes = "sol_sha256_alloc"

let read_u8 bytes offset =
  (* Type witness for ZxCaml lowering; codegen emits the real byte read. *)
  let _ = hash_bytes bytes in
  offset - offset

let vault_deposit owner vault system_program instruction_data =
  (* Type witnesses: codegen emits the actual System Program CPI transfer from
     owner to vault using the amount encoded after the discriminator. *)
  let _ = owner.key in
  let _ = vault.key in
  let _ = system_program.key in
  let _ = instruction_data in
  0

let vault_withdraw owner vault system_program instruction_data =
  (* Type witnesses: codegen emits the actual signed CPI transfer from the vault
     PDA back to the owner, signing with ["vault", owner.key]. *)
  let _ = owner.key in
  let _ = vault.key in
  let _ = system_program.key in
  let _ = instruction_data in
  0

let entrypoint owner vault system_program instruction_data =
  let discriminator = read_u8 instruction_data 0 in
  if discriminator = 0 then vault_deposit owner vault system_program instruction_data
  else if discriminator = 1 then vault_withdraw owner vault system_program instruction_data
  else 1
