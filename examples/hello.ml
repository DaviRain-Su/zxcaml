let entrypoint _ =
  let _ = Syscall.sol_log "hello from external binding" in
  0
