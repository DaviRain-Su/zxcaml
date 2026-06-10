(* AccountMeta constructor helpers.

   Builds CPI account metas with each `AccountMeta.*` constructor instead of
   raw record literals, then reads every privilege flag back. The entrypoint
   returns 0 when all checks pass and a positive code naming the first failed
   constructor otherwise, so `omlz run` has a deterministic result. *)

(* `AccountMeta.of_account` forwards an account's own privileges into a CPI
   meta — the most common flow. Accounts only exist at runtime, so the helper
   is exercised through this function, ready to be applied to a real
   entrypoint account. *)
let forward_meta (authority : account) = AccountMeta.of_account authority

let entrypoint _ =
  let writable = AccountMeta.writable Pubkey.zero in
  let signer = AccountMeta.signer Pubkey.zero in
  let writable_signer = AccountMeta.writable_signer Pubkey.zero in
  let readonly = AccountMeta.readonly Pubkey.zero in
  if not (writable.is_writable && not writable.is_signer) then 1
  else if not ((not signer.is_writable) && signer.is_signer) then 2
  else if not (writable_signer.is_writable && writable_signer.is_signer) then 3
  else if readonly.is_writable || readonly.is_signer then 4
  else if not (Bytes.equal writable.pubkey Pubkey.zero) then 5
  else 0
