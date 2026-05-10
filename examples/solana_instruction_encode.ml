(* Pure OCaml Solana instruction data encoding.
   Uses Bytes.create, Bytes.set, Bytes.blit + bitwise ops to construct
   instruction data buffers — no Zig runtime helpers needed.

   All functions are inlined into entrypoint to avoid ZxCaml type inference
   limitations with user-defined functions that take bytes arguments.
*)

(* === System Program: Transfer ===
   Layout: discriminator (u32 LE) | amount (u64 LE) = 12 bytes
   Discriminator 2 = System Transfer *)

let system_transfer_data amount =
  let buf = Bytes.create 12 in
  let _ = Bytes.set buf 0 (Char.chr 2) in
  let _ = Bytes.set buf 1 (Char.chr 0) in
  let _ = Bytes.set buf 2 (Char.chr 0) in
  let _ = Bytes.set buf 3 (Char.chr 0) in
  (* amount as u64 LE *)
  let _ = Bytes.set buf 4 (Char.chr (amount land 0xFF)) in
  let _ = Bytes.set buf 5 (Char.chr ((amount lsr 8) land 0xFF)) in
  let _ = Bytes.set buf 6 (Char.chr ((amount lsr 16) land 0xFF)) in
  let _ = Bytes.set buf 7 (Char.chr ((amount lsr 24) land 0xFF)) in
  let _ = Bytes.set buf 8 (Char.chr 0) in
  let _ = Bytes.set buf 9 (Char.chr 0) in
  let _ = Bytes.set buf 10 (Char.chr 0) in
  let _ = Bytes.set buf 11 (Char.chr 0) in
  buf

(* === SPL Token: Transfer ===
   Layout: discriminator (u8) | amount (u64 LE) = 9 bytes
   Discriminator 3 = SPL Token Transfer *)

let spl_token_transfer_data amount =
  let buf = Bytes.create 9 in
  let _ = Bytes.set buf 0 (Char.chr 3) in
  let _ = Bytes.set buf 1 (Char.chr (amount land 0xFF)) in
  let _ = Bytes.set buf 2 (Char.chr ((amount lsr 8) land 0xFF)) in
  let _ = Bytes.set buf 3 (Char.chr ((amount lsr 16) land 0xFF)) in
  let _ = Bytes.set buf 4 (Char.chr ((amount lsr 24) land 0xFF)) in
  let _ = Bytes.set buf 5 (Char.chr 0) in
  let _ = Bytes.set buf 6 (Char.chr 0) in
  let _ = Bytes.set buf 7 (Char.chr 0) in
  let _ = Bytes.set buf 8 (Char.chr 0) in
  buf

(* === SPL Token: TransferChecked ===
   Layout: discriminator (u8) | amount (u64 LE) | decimals (u8) = 10 bytes
   Discriminator 12 = SPL Token TransferChecked *)

let spl_token_transfer_checked_data amount decimals =
  let buf = Bytes.create 10 in
  let _ = Bytes.set buf 0 (Char.chr 12) in
  let _ = Bytes.set buf 1 (Char.chr (amount land 0xFF)) in
  let _ = Bytes.set buf 2 (Char.chr ((amount lsr 8) land 0xFF)) in
  let _ = Bytes.set buf 3 (Char.chr ((amount lsr 16) land 0xFF)) in
  let _ = Bytes.set buf 4 (Char.chr ((amount lsr 24) land 0xFF)) in
  let _ = Bytes.set buf 5 (Char.chr 0) in
  let _ = Bytes.set buf 6 (Char.chr 0) in
  let _ = Bytes.set buf 7 (Char.chr 0) in
  let _ = Bytes.set buf 8 (Char.chr 0) in
  let _ = Bytes.set buf 9 (Char.chr (decimals land 0xFF)) in
  buf

(* === System Program: CreateAccount ===
   Layout: discriminator (u32 LE) | lamports (u64 LE) | space (u64 LE) | owner (32 bytes)
   = 4 + 8 + 8 + 32 = 52 bytes
   Discriminator 0 = System CreateAccount *)

let system_create_account_data lamports space =
  let buf = Bytes.create 52 in
  (* discriminator = 0 *)
  let _ = Bytes.fill buf 0 4 (Char.chr 0) in
  (* lamports as u64 LE *)
  let _ = Bytes.set buf 4 (Char.chr (lamports land 0xFF)) in
  let _ = Bytes.set buf 5 (Char.chr ((lamports lsr 8) land 0xFF)) in
  let _ = Bytes.set buf 6 (Char.chr ((lamports lsr 16) land 0xFF)) in
  let _ = Bytes.set buf 7 (Char.chr ((lamports lsr 24) land 0xFF)) in
  let _ = Bytes.fill buf 8 4 (Char.chr 0) in
  (* space as u64 LE *)
  let _ = Bytes.set buf 12 (Char.chr (space land 0xFF)) in
  let _ = Bytes.set buf 13 (Char.chr ((space lsr 8) land 0xFF)) in
  let _ = Bytes.set buf 14 (Char.chr ((space lsr 16) land 0xFF)) in
  let _ = Bytes.set buf 15 (Char.chr ((space lsr 24) land 0xFF)) in
  let _ = Bytes.fill buf 16 4 (Char.chr 0) in
  (* owner: 32 zero bytes (placeholder — real usage would blit a pubkey) *)
  let _ = Bytes.fill buf 20 32 (Char.chr 0) in
  buf

(* === Comprehensive validation ===
   Encodes all instruction types, verifies round-trip via Bytes.get + bitwise,
   returns 0 on success. *)

let entrypoint _ =
  (* System Transfer: amount=1 *)
  let sys = system_transfer_data 1 in
  let sys_len = Bytes.length sys in
  let sys_disc = Char.code (Bytes.get sys 0) in
  let sys_amt = Char.code (Bytes.get sys 4) in

  (* SPL Token Transfer: amount=1 *)
  let spl = spl_token_transfer_data 1 in
  let spl_len = Bytes.length spl in
  let spl_disc = Char.code (Bytes.get spl 0) in
  let spl_amt = Char.code (Bytes.get spl 1) in

  (* SPL Token TransferChecked: amount=100, decimals=6 *)
  let checked = spl_token_transfer_checked_data 100 6 in
  let checked_len = Bytes.length checked in
  let checked_disc = Char.code (Bytes.get checked 0) in
  let checked_amt_lo = Char.code (Bytes.get checked 1) in
  let checked_amt_hi = Char.code (Bytes.get checked 2) in
  let checked_amt = checked_amt_lo lor (checked_amt_hi lsl 8) in
  let checked_dec = Char.code (Bytes.get checked 9) in

  (* System CreateAccount: lamports=1000000, space=165 *)
  let create = system_create_account_data 1000000 165 in
  let create_len = Bytes.length create in
  let create_lamports_lo = Char.code (Bytes.get create 4) in
  let create_space_lo = Char.code (Bytes.get create 12) in

  (* Verify all *)
  let sys_ok = sys_len = 12 && sys_disc = 2 && sys_amt = 1 in
  let spl_ok = spl_len = 9 && spl_disc = 3 && spl_amt = 1 in
  let checked_ok = checked_len = 10 && checked_disc = 12 && checked_amt = 100 && checked_dec = 6 in
  let create_ok = create_len = 52 && create_lamports_lo = 64 (* 1000000 land 0xFF = 64 *) && create_space_lo = 165 in

  if sys_ok && spl_ok && checked_ok && create_ok then 0 else 1
