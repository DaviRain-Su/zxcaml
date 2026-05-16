let entrypoint input =
  let digest = Crypto.blake3 input in
  let _ = Syscall.sol_log_pubkey digest in
  0
