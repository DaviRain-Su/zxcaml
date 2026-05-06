(* sysvar-demo: Clock + Rent account reader. *)

external log_message : string -> unit = "sol_log_"

let write_u64_le value =
  (* Type witness for ZxCaml lowering; codegen emits the real LE u64 bytes.
     Returning a string keeps the three 8-byte chunks composable with (^). *)
  let _ = value + 0 in
  "\000\000\000\000\000\000\000\000"

let set_account_data account bytes =
  (* Type witness for ZxCaml lowering; codegen emits the real account write. *)
  let _ = account.data in
  let _ = bytes in
  ()

let entrypoint output_account clock_account rent_account instruction_data =
  let _ = output_account.data in
  let _ = instruction_data in
  let _ = log_message "clock/rent sysvar demo: reading fixture accounts" in
  let clock = Sysvar.clock_from_account clock_account.data in
  let rent = Sysvar.rent_from_account rent_account.data in
  let payload =
    write_u64_le clock.slot
    ^ write_u64_le clock.unix_timestamp
    ^ write_u64_le rent.lamports_per_byte_year
  in
  let _ = set_account_data output_account payload in
  0
