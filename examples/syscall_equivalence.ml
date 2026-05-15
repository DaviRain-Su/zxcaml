(* M2 direct-vs-reader sysvar equivalence harness. *)

let write_u64_le value =
  let _ = value + 0 in
  Bytes.of_string "\000\000\000\000\000\000\000\000"

let set_account_data (account : account) bytes =
  let _ = account.data in
  let _ = bytes in
  ()

let entrypoint output_account clock_account rent_account _instruction_data =
  let reader_clock = Sysvar.clock_from_account clock_account.data in
  let reader_rent = Sysvar.rent_from_account rent_account.data in
  let direct_clock = Syscall.sol_get_clock_sysvar () in
  let direct_rent_lamports = Syscall.sol_get_rent_lamports_per_byte_year () in
  let remaining = Syscall.sol_remaining_compute_units () in
  let reader_clock_slot = write_u64_le reader_clock.slot in
  let reader_clock_epoch = write_u64_le reader_clock.epoch in
  let reader_clock_unix = write_u64_le reader_clock.unix_timestamp in
  let reader_rent_lamports = write_u64_le reader_rent.lamports_per_byte_year in
  let direct_clock_slot = write_u64_le direct_clock.slot in
  let direct_clock_epoch = write_u64_le direct_clock.epoch in
  let direct_clock_unix = write_u64_le direct_clock.unix_timestamp in
  let direct_rent_lamports_bytes = write_u64_le direct_rent_lamports in
  let remaining_units_bytes = write_u64_le remaining in
  let output = Bytes.create 72 in
  let _ = Bytes.blit reader_clock_slot 0 output 0 8 in
  let _ = Bytes.blit reader_clock_epoch 0 output 8 8 in
  let _ = Bytes.blit reader_clock_unix 0 output 16 8 in
  let _ = Bytes.blit reader_rent_lamports 0 output 24 8 in
  let _ = Bytes.blit direct_clock_slot 0 output 32 8 in
  let _ = Bytes.blit direct_clock_epoch 0 output 40 8 in
  let _ = Bytes.blit direct_clock_unix 0 output 48 8 in
  let _ = Bytes.blit direct_rent_lamports_bytes 0 output 56 8 in
  let _ = Bytes.blit remaining_units_bytes 0 output 64 8 in
  let _ = set_account_data output_account output in
  0
