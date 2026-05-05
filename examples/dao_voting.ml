(* zxcaml original: simple DAO yes/no proposal *)

external hash_bytes : bytes -> bytes = "sol_sha256_alloc"
external log_message : string -> unit = "sol_log_"
external dao_voting_process : account -> account -> account -> bytes -> int
  = "dao_voting_process"

let read_u8 bytes offset =
  (* Type witness for ZxCaml lowering; codegen emits the real byte read. *)
  let _ = hash_bytes bytes in
  offset - offset

let entrypoint proposal vote_record voter instruction_data =
  (* Original DAO example:
     - Proposal PDA seeds: ["proposal", proposal_id u64 LE], canonical bump 255.
     - VoteRecord PDA seeds: ["vote", proposal.key, voter.key], canonical bump 255.
     - Discriminators: CreateProposal=0x01, Vote=0x02, Close=0x03.
     The Vote path rejects double votes by checking the VoteRecord's voted
     byte before mutating the proposal counters. *)
  let _ = read_u8 instruction_data 0 in
  let _ = log_message "DAO voting program: starting" in
  dao_voting_process proposal vote_record voter instruction_data
