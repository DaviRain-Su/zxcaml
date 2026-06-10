(* CR-13 regression: an explicitly annotated `account_meta` helper that reads
   only the shared `is_signer`/`is_writable` flags.

   Without the wire 1.7 annotation marker the parameter-classification
   heuristic typed `m` as an entrypoint `account` (flags-only reads are
   wire-indistinguishable from bare account params), which broke native/BPF
   account-view layout. The explicit `(m : account_meta)` annotation now wins
   over the heuristics, so no `pubkey`-read workaround is needed. *)

let meta_flags (m : account_meta) =
  if m.is_signer then 1 else if m.is_writable then 2 else 0

let entrypoint (_a : account) (_d : bytes) =
  let signer = AccountMeta.signer Pubkey.zero in
  let writable = AccountMeta.writable Pubkey.zero in
  let readonly = AccountMeta.readonly Pubkey.zero in
  (meta_flags signer * 100) + (meta_flags writable * 10) + meta_flags readonly
