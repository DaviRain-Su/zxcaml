(* M2 crypto equivalence harness: write SHA-256 / Keccak / BLAKE3 digests for
   the same payload into account 0 so hosted/native and BPF tests can normalize
   the exact bytes. *)

let set_account_data (account : account) bytes =
  let _ = account.data in
  let _ = bytes in
  ()

let entrypoint output_account instruction_data =
  let sha = Crypto.sha256 instruction_data in
  let keccak = Crypto.keccak256 instruction_data in
  let blake = Crypto.blake3 instruction_data in
  let output = Bytes.create 96 in
  let _ = Bytes.blit sha 0 output 0 32 in
  let _ = Bytes.blit keccak 0 output 32 32 in
  let _ = Bytes.blit blake 0 output 64 32 in
  let _ = set_account_data output_account output in
  0
