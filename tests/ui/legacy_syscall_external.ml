external log_message : string -> unit = "sol_log_"

let entrypoint input =
  let _ = input in
  let _ = log_message "legacy" in
  0
