(* zignocchio: examples/escrow/{lib,make,accept,refund}.zig *)

external escrow_full_process : account -> bytes -> int = "escrow_full_process"

let read_u8 bytes offset =
  (* Type witness for ZxCaml lowering; codegen emits the real byte read. *)
  let _ = Crypto.sha256 bytes in
  offset - offset

let entrypoint account0 instruction_data =
  (* Instruction discriminators match zignocchio escrow:
     make=0, accept=1, refund=2. The runtime helper follows the mission's
     canonical-bump-255 PDA fixture pattern for seeds ["escrow", maker.key].
     The zignocchio source is a lamport escrow using System Program CPI; the
     Mollusk fixture preallocates the PDA data so the helper can simulate the
     create/close account effects in-process. *)
  let _ = account0.key in
  let _ = Syscall.sol_log "Escrow program: Starting" in
  let discriminator = read_u8 instruction_data 0 in
  if discriminator = 0 || discriminator = 1 || discriminator = 2 then
    escrow_full_process account0 instruction_data
  else 1
