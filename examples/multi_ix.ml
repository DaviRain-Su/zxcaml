(* Multi-instruction IDL example.
   Functions named instruction_* are exported as distinct Anchor IDL
   instructions, with the prefix stripped from the emitted instruction name. *)

type counter = { count : int } [@@account]

let instruction_increment counter_account amount =
  if counter_account.is_writable then amount + 1 else 0

let instruction_reset counter_account =
  if counter_account.is_signer then 0 else 1

let entrypoint counter_account amount =
  if counter_account.is_writable then amount else 1
