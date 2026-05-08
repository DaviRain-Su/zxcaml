(* cgrt23: return-data syscall round-trip demo. *)

external set_return_data : bytes -> unit = "Cpi.set_return_data"
external get_return_data : unit -> bytes = "Cpi.get_return_data"
external log_message : string -> unit = "sol_log_"

let set_account_data (account : account) bytes =
  (* Type witness for ZxCaml lowering; codegen emits the real account data
     write, copying the return-data payload into writable account 0. *)
  let _ = account.data in
  let _ = bytes in
  ()

let entrypoint output_account instruction_data =
  let _ = output_account.key in
  let _ = log_message "return-data demo: round-tripping instruction data" in
  let _ = set_return_data instruction_data in
  let _ = set_account_data output_account instruction_data in
  0
