(* First PDA derivation example: `Pda.create_program_address` takes the
   signer seeds (a `bytes array`) and a program id, and returns the derived
   program address as `bytes`. `Pda.try_find_program_address` takes the same
   arguments and returns `(bytes * int) option`: `Some (address, bump)` on
   success, `None` when no valid address exists.

   Execution semantics per target:
   - On BPF the real sha256-based derivation runs via the
     `sol_create_program_address` syscall, and the real bump search runs for
     `try_find_program_address`.
   - The interpreter (`omlz run`) and `--target=native` use the documented
     deterministic off-chain stubs from `stdlib/core.ml`: the seeds are
     ignored, `create_program_address` returns the program id unchanged, and
     `try_find_program_address` returns `Some (program_id, 0)`. That keeps
     the interpreter ≡ native determinism gate meaningful without a Solana
     VM.

   Each helper lives in its own function so the BPF build keeps one sha256
   derivation per stack frame (two inlined derivations overflow the 4 KiB
   SBF frame limit). *)

(* Off-chain the stub returns the program id, so this flag is 0 in the
   interpreter and in native builds; on BPF the derived address differs from
   the program id and the flag is 1. *)
let check_create (program_id : bytes) =
  (* "vault" prefix plus a one-byte bump seed, like on-chain PDA schemes. *)
  let bump = Bytes.of_string "\255" in
  let seeds = Array.of_list [ Bytes.of_string "vault"; bump ] in
  let addr = Pda.create_program_address seeds program_id in
  if Bytes.equal addr program_id then 0 else 1

(* `try_find_program_address` takes the seed prefix without the bump and
   searches for one. Off-chain the stub deterministically yields
   `Some (program_id, 0)`, so this flag is 0; on BPF the real bump search
   runs, the found address differs from the program id, and the flag is 2. *)
let check_find (program_id : bytes) =
  let find_seeds = Array.of_list [ Bytes.of_string "vault" ] in
  match Pda.try_find_program_address find_seeds program_id with
  | Some (found_addr, found_bump) ->
      if Bytes.equal found_addr program_id && found_bump = 0 then 0 else 2
  | None -> 4

let entrypoint (_account : account) (_data : bytes) =
  let program_id = Pubkey.zero in
  (* Deterministic per target: 0 off-chain, 3 on BPF. *)
  check_create program_id + check_find program_id
