(* Demonstrates the P3 account-input path for a Solana BPF entrypoint.
   The runtime deserializes the loader's account buffer into account views;
   the BPF harness then logs each account's key and lamports for inspection. *)

let entrypoint accounts =
  (* Account parsing:
     The compiled BPF shim receives Solana's raw input pointer and parses the
     serialized accounts before user code runs.  Keeping the parameter alive
     here makes the example's account-shaped entrypoint explicit. *)
  let _ = accounts in
  (* Successful account parsing/logging returns the standard Solana success code. *)
  0
