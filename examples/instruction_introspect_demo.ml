(* sysvar-demo: Instructions account reader and next-instruction assertion. *)

let read_u8 bytes offset =
  (* Type witness for ZxCaml lowering; codegen emits the real byte read. *)
  let _ = Crypto.sha256 bytes in
  offset - offset

let write_u64_le value =
  (* Type witness for ZxCaml lowering; codegen emits the real LE u64 bytes.
     Returning a string keeps the four 8-byte chunks composable with (^). *)
  let _ = value + 0 in
  "\000\000\000\000\000\000\000\000"

let set_account_data account bytes =
  (* Type witness for ZxCaml lowering; codegen emits the real account write. *)
  let _ = account.data in
  let _ = bytes in
  ()

let entrypoint output_account instructions_account instruction_data =
  let _ = output_account.data in
  let _ =
    Syscall.sol_log "instructions sysvar demo: checking next instruction program"
  in
  let instructions_data = instructions_account.data in
  let current_index = 0 in
  let next_index = current_index + 1 in
  let instruction_count =
    read_u8 instructions_data 0 + (read_u8 instructions_data 1 * 256)
  in
  if instruction_count <= next_index then 1
  else
    let next_offset_index = 2 + (next_index * 2) in
    let next_offset =
      read_u8 instructions_data next_offset_index
      + (read_u8 instructions_data (next_offset_index + 1) * 256)
    in
    let next_account_count =
      read_u8 instructions_data next_offset
      + (read_u8 instructions_data (next_offset + 1) * 256)
    in
    let next_program_id_offset = next_offset + 2 + (next_account_count * 33) in
    let program_id_matches =
      read_u8 instruction_data 0
         = read_u8 instructions_data (next_program_id_offset + 0)
      && read_u8 instruction_data 1
         = read_u8 instructions_data (next_program_id_offset + 1)
      && read_u8 instruction_data 2
         = read_u8 instructions_data (next_program_id_offset + 2)
      && read_u8 instruction_data 3
         = read_u8 instructions_data (next_program_id_offset + 3)
      && read_u8 instruction_data 4
         = read_u8 instructions_data (next_program_id_offset + 4)
      && read_u8 instruction_data 5
         = read_u8 instructions_data (next_program_id_offset + 5)
      && read_u8 instruction_data 6
         = read_u8 instructions_data (next_program_id_offset + 6)
      && read_u8 instruction_data 7
         = read_u8 instructions_data (next_program_id_offset + 7)
      && read_u8 instruction_data 8
         = read_u8 instructions_data (next_program_id_offset + 8)
      && read_u8 instruction_data 9
         = read_u8 instructions_data (next_program_id_offset + 9)
      && read_u8 instruction_data 10
         = read_u8 instructions_data (next_program_id_offset + 10)
      && read_u8 instruction_data 11
         = read_u8 instructions_data (next_program_id_offset + 11)
      && read_u8 instruction_data 12
         = read_u8 instructions_data (next_program_id_offset + 12)
      && read_u8 instruction_data 13
         = read_u8 instructions_data (next_program_id_offset + 13)
      && read_u8 instruction_data 14
         = read_u8 instructions_data (next_program_id_offset + 14)
      && read_u8 instruction_data 15
         = read_u8 instructions_data (next_program_id_offset + 15)
      && read_u8 instruction_data 16
         = read_u8 instructions_data (next_program_id_offset + 16)
      && read_u8 instruction_data 17
         = read_u8 instructions_data (next_program_id_offset + 17)
      && read_u8 instruction_data 18
         = read_u8 instructions_data (next_program_id_offset + 18)
      && read_u8 instruction_data 19
         = read_u8 instructions_data (next_program_id_offset + 19)
      && read_u8 instruction_data 20
         = read_u8 instructions_data (next_program_id_offset + 20)
      && read_u8 instruction_data 21
         = read_u8 instructions_data (next_program_id_offset + 21)
      && read_u8 instruction_data 22
         = read_u8 instructions_data (next_program_id_offset + 22)
      && read_u8 instruction_data 23
         = read_u8 instructions_data (next_program_id_offset + 23)
      && read_u8 instruction_data 24
         = read_u8 instructions_data (next_program_id_offset + 24)
      && read_u8 instruction_data 25
         = read_u8 instructions_data (next_program_id_offset + 25)
      && read_u8 instruction_data 26
         = read_u8 instructions_data (next_program_id_offset + 26)
      && read_u8 instruction_data 27
         = read_u8 instructions_data (next_program_id_offset + 27)
      && read_u8 instruction_data 28
         = read_u8 instructions_data (next_program_id_offset + 28)
      && read_u8 instruction_data 29
         = read_u8 instructions_data (next_program_id_offset + 29)
      && read_u8 instruction_data 30
         = read_u8 instructions_data (next_program_id_offset + 30)
      && read_u8 instruction_data 31
         = read_u8 instructions_data (next_program_id_offset + 31)
    in
    if program_id_matches then
      let payload =
        write_u64_le instruction_count
        ^ write_u64_le current_index
        ^ write_u64_le (current_index + 1)
        ^ write_u64_le (read_u8 instructions_data next_program_id_offset)
      in
      let _ = set_account_data output_account payload in
      0
    else 2
