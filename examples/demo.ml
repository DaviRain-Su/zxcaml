(* ZxCaml Hackathon Demo
   Demonstrates: OCaml -> Solana BPF compiler
   Features shown: type inference, pattern matching, ADTs, syscalls, accounts *)

let entrypoint accounts input =
  (* 1. Pattern matching with Options *)
  let x = Some 42 in
  let result =
    match x with
    | Some n -> n
    | None -> 0
  in
  (* 2. Tuple pattern matching *)
  let final =
    match (result, true) with
    | (value, flag) -> if flag then value else 0
  in
  (* 3. Log via syscall *)
  let _ = Syscall.sol_log "ZxCaml demo" in
  let _ = Syscall.sol_log_64 final 0 0 0 0 in
  (* 4. Account awareness *)
  let _ = accounts in
  let _ = input in
  0
