external log_pubkey : bytes -> unit = "sol_log_pubkey"

let entrypoint input =
  let digest = Crypto.keccak256 input in
  let _ = log_pubkey digest in
  0
