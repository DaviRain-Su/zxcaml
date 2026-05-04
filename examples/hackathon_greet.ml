(* hackathon: greeting counter — Colosseum demo *)

external hash_bytes : bytes -> bytes = "sol_sha256_alloc"
external log_message : string -> unit = "sol_log_"
external hackathon_greet_process : account -> account -> bytes -> int
  = "hackathon_greet_process"

let read_u8 bytes offset =
  (* Type witness for ZxCaml lowering; codegen emits the real byte read. *)
  let _ = hash_bytes bytes in
  offset - offset

let instruction_init (greeting_account : account) (maker : account) =
  (* IDL-only export: the runtime entrypoint dispatches discriminator 0 to the
     same helper below, while `omlz idl` discovers instruction_* functions as
     Anchor instructions. *)
  if greeting_account.is_writable then
    if maker.is_signer then 0 else 1
  else 1

let instruction_greet (greeting_account : account) (maker : account) =
  (* IDL-only export: discriminator 1 increments the greeting state and records
     maker on the first greet in the runtime helper. *)
  if greeting_account.is_writable then
    if maker.is_signer then 0 else 1
  else 1

let entrypoint greeting_account maker instruction_data =
  (* The greeting account is the PDA derived from ["greet", maker.key].
     The Mollusk fixture follows the repository's canonical bump-255 PDA
     pattern: tests choose a maker whose canonical PDA bump is 255, and the
     runtime helper verifies that exact bumped address. *)
  let _ = log_message "hackathon_greet: dispatch" in
  let discriminator = read_u8 instruction_data 0 in
  if discriminator = 0 then
    hackathon_greet_process greeting_account maker instruction_data
  else if discriminator = 1 then
    hackathon_greet_process greeting_account maker instruction_data
  else 1
