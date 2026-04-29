external log_message : string -> unit = "sol_log_"

let entrypoint _ =
  let _ = log_message "hello from external binding" in
  0
