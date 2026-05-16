let entrypoint input =
  let digest = Crypto.keccak256 input in
  let _ = Syscall.sol_log_pubkey digest in
  0
