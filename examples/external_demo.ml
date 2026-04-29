(* Demonstrates custom OCaml names bound directly to Zig runtime symbols with
   external declarations. *)

external emit_log : string -> unit = "sol_log_"
external emit_values : int -> int -> int -> int -> int -> unit = "sol_log_64_"
external remaining_units : unit -> int = "sol_remaining_compute_units"

let entrypoint _ =
  let remaining = remaining_units () in
  let _ = emit_log "external demo" in
  let _ = emit_values 7 remaining 0 0 0 in
  0
