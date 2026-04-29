let entrypoint _ =
  let _ = Syscall.sol_sha256 "zxcaml" in
  let clock = Syscall.sol_get_clock_sysvar () in
  let remaining = Syscall.sol_remaining_compute_units () in
  let _ = Syscall.sol_log "syscall test" in
  let _ =
    Syscall.sol_log_64 clock.slot clock.epoch clock.unix_timestamp remaining 0
  in
  0
