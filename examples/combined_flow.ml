external combined_process :
  account ->
  account ->
  account ->
  account ->
  account ->
  account ->
  account ->
  int = "combined_process"

let set_account_data (account : account) bytes =
  let _ = account.data in
  let _ = Bytes.length bytes in
  ()

let entrypoint (output_account : account) (clock_account : account)
    (rent_account : account) (greeting_account : account) (owner : account)
    (recipient : account) (system_program : account) instruction_data =
  let digest = Crypto.sha256 instruction_data in
  let direct_clock = Syscall.sol_get_clock_sysvar () in
  let reader_clock = Sysvar.clock_from_account clock_account.data in
  let direct_rent = Syscall.sol_get_rent_lamports_per_byte_year () in
  let reader_rent = Sysvar.rent_from_account rent_account.data in
  let remaining = Syscall.sol_remaining_compute_units () in
  let _ = Syscall.sol_log "combined flow: start" in
  let _ = Syscall.sol_log_pubkey digest in
  let _ =
    Syscall.sol_log_64 direct_clock.slot reader_clock.slot direct_rent
      reader_rent.lamports_per_byte_year remaining
  in
  let status =
    combined_process output_account clock_account rent_account greeting_account
      owner recipient system_program
  in
  if status = 0 then (
    let _ = Cpi.set_return_data instruction_data in
    let _ = set_account_data output_account digest in
    0)
  else status
