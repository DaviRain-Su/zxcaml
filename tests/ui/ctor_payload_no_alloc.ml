type event = Logged of int

let entrypoint (a : account) (data : bytes) =
  let _ = data in
  let e = Logged (Account.lamports a) in
  match e with
  | Logged n -> n
