(* First PDA derivation example: `Pda.create_program_address` takes the
   signer seeds (a `bytes array`) and a program id, and returns the derived
   program address as `bytes`.

   Execution semantics per target:
   - On BPF the real sha256-based derivation runs via the
     `sol_create_program_address` syscall.
   - The interpreter (`omlz run`) and `--target=native` use the documented
     deterministic off-chain stub from `stdlib/core.ml`: the seeds are
     ignored and the program id is returned unchanged. That keeps the
     interpreter ≡ native determinism gate meaningful without a Solana VM. *)

let entrypoint (_account : account) (_data : bytes) =
  let program_id = Pubkey.zero in
  (* "vault" prefix plus a one-byte bump seed, like on-chain PDA schemes. *)
  let bump = Bytes.of_string "\255" in
  let seeds = Array.of_list [ Bytes.of_string "vault"; bump ] in
  let addr = Pda.create_program_address seeds program_id in
  (* Off-chain the stub returns the program id, so this branch returns 0 in
     the interpreter and in native builds; on BPF the derived address differs
     from the program id and the program returns 1. *)
  if Bytes.equal addr program_id then 0 else 1
