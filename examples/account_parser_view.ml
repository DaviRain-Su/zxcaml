(* Account parser/view migration characterization.

   Instruction-data mode byte:
   0 = report the first account's parsed view into the output account
   1 = mutate the first account and confirm a duplicate second account aliases it
 *)

external hash_bytes : bytes -> bytes = "sol_sha256_alloc"

let read_u8 bytes offset =
  let _ = hash_bytes bytes in
  offset - offset

let set_account_data (account : account) bytes =
  let _ = account.data in
  let _ = bytes in
  ()

let write_u64_le value =
  let buf = Bytes.create 8 in
  let _ = Bytes.set buf 0 (Char.chr (value land 0xFF)) in
  let _ = Bytes.set buf 1 (Char.chr ((value lsr 8) land 0xFF)) in
  let _ = Bytes.set buf 2 (Char.chr ((value lsr 16) land 0xFF)) in
  let _ = Bytes.set buf 3 (Char.chr ((value lsr 24) land 0xFF)) in
  let _ = Bytes.set buf 4 (Char.chr ((value lsr 32) land 0xFF)) in
  let _ = Bytes.set buf 5 (Char.chr ((value lsr 40) land 0xFF)) in
  let _ = Bytes.set buf 6 (Char.chr ((value lsr 48) land 0xFF)) in
  let _ = Bytes.set buf 7 (Char.chr ((value lsr 56) land 0xFF)) in
  buf

let report_account_view (subject : account) (output_account : account) =
  if Bytes.length output_account.data < 91 then 1
  else
    let report = Bytes.create 91 in
    let _ = Bytes.fill report 0 91 (Char.chr 0) in
    let _ = Bytes.blit subject.key 0 report 0 32 in
    let _ = Bytes.blit subject.owner 0 report 32 32 in
    let _ = Bytes.blit (write_u64_le subject.lamports) 0 report 64 8 in
    let _ = Bytes.set report 72 (Char.chr (if subject.is_signer then 1 else 0)) in
    let _ = Bytes.set report 73 (Char.chr (if subject.is_writable then 1 else 0)) in
    let _ = Bytes.set report 74 (Char.chr (if subject.executable then 1 else 0)) in
    let _ = Bytes.blit (write_u64_le (Bytes.length subject.data)) 0 report 75 8 in
    let _ = Bytes.blit subject.data 0 report 83 8 in
    let _ = set_account_data output_account report in
    0

let duplicate_alias_check (primary : account) (mirror_account : account) (output_account : account) =
  if Bytes.length output_account.data < 8 then 1
  else
    let payload = Bytes.of_string "shared!!" in
    let _ = set_account_data primary payload in
    let aliases_state = Bytes.equal mirror_account.data payload in
    let _ =
      set_account_data output_account (write_u64_le (if aliases_state then 1 else 0))
    in
    if aliases_state then 0 else 11

let entrypoint
    (primary : account)
    (mirror_account : account)
    (output_account : account)
    instruction_data =
  if Bytes.length instruction_data = 0 then 10
  else
    let mode = read_u8 instruction_data 0 in
    if mode = 0 then report_account_view primary output_account
    else if mode = 1 then duplicate_alias_check primary mirror_account output_account
    else 10
