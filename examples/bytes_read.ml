(* Test read-only Bytes operations: Bytes.get, Bytes.length, Bytes.sub.
   Returns 0 on success (determinism corpus expects native ≡ interpreter). *)

let entrypoint _ =
  let data = Bytes.of_string "ABCDE" in
  let len = Bytes.length data in
  let b0 = Char.code (Bytes.get data 0) in
  let b4 = Char.code (Bytes.get data 4) in
  let sub = Bytes.sub data 1 3 in
  let sub_len = Bytes.length sub in
  let sub_b0 = Char.code (Bytes.get sub 0) in
  let sub_b2 = Char.code (Bytes.get sub 2) in
  (* len=5, b0=65('A'), b4=69('E'), sub="BCD", sub_len=3, sub_b0=66('B'), sub_b2=68('D') *)
  if len = 5 && b0 = 65 && b4 = 69 && sub_len = 3 && sub_b0 = 66 && sub_b2 = 68 then 0
  else 1
