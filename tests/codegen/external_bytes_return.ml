external sol_sha256 : bytes -> bytes = "sol_sha256"
external sol_log : bytes -> unit = "sol_log_"

let entrypoint input =
  let digest = sol_sha256 input in
  let _ = sol_log digest in
  0
