(* ZxCaml Hackathon Demo
   Demonstrates: OCaml -> Solana BPF compiler
   Features shown: type inference and external syscall bindings *)

external log_message : string -> unit = "sol_log_"
external log_values : int -> int -> int -> int -> int -> unit = "sol_log_64_"

let entrypoint _ =
  (* 1. Log via external syscall bindings *)
  let _ = log_message "ZxCaml demo" in
  let _ = log_values 42 0 0 0 0 in
  0
