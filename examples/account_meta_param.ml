(* CR-13 regression: a helper taking an `account_meta` parameter.

   Reading `m.pubkey` — the field unique to `account_meta` — is what keeps
   the param-classification heuristic from treating `m` as an entrypoint
   `account` when the parameter is *unannotated*. Since wire 1.7, an
   explicit `(m : account_meta)` annotation alone suffices — annotations
   beat the heuristics (see `examples/account_meta_annotated.ml`); the
   `pubkey`-read veto remains relevant only for unannotated params. *)

let meta_summary (m : account_meta) =
  let _ = m.pubkey in
  if m.is_signer then 1 else if m.is_writable then 2 else 0

let entrypoint (_a : account) (_d : bytes) =
  let signer = AccountMeta.signer Pubkey.zero in
  let writable = AccountMeta.writable Pubkey.zero in
  let readonly = AccountMeta.readonly Pubkey.zero in
  (meta_summary signer * 100) + (meta_summary writable * 10) + meta_summary readonly
