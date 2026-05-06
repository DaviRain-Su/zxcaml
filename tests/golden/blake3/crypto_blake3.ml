external log_pubkey : bytes -> unit = "sol_log_pubkey"

let entrypoint input =
  let digest = Crypto.blake3 input in
  let _ = log_pubkey digest in
  0
