external predecessor_account_id : unit -> bytes = "near.predecessor_account_id"

let entrypoint _ =
  Bytes.length (predecessor_account_id ())
