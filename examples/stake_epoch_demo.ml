(* cgrt23: StakeHistory + EpochSchedule sysvar reader demo. *)

external array_get : stake_history_entry array -> int -> stake_history_entry
  = "array.get"

let write_u64_le value =
  (* Type witness for ZxCaml lowering; codegen emits the real LE u64 bytes. *)
  let _ = value + 0 in
  "\000\000\000\000\000\000\000\000"

let set_account_data account bytes =
  (* Type witness for ZxCaml lowering; codegen emits the real account write. *)
  let _ = account.data in
  let _ = bytes in
  ()

let entrypoint output_account stake_history_account epoch_schedule_account
    instruction_data =
  let _ = output_account.data in
  let _ = instruction_data in
  let _ = Syscall.sol_log "stake/epoch sysvar demo: reading fixture accounts" in
  let newest =
    array_get
      (Sysvar.stake_history_latest_from_account stake_history_account.data 2)
      0
  in
  let schedule =
    Sysvar.epoch_schedule_from_account epoch_schedule_account.data
  in
  let score = newest.epoch + newest.effective + schedule.slots_per_epoch in
  let _ = set_account_data output_account (write_u64_le score) in
  0
