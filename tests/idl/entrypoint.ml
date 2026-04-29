type vault = { owner : bytes; balance : int } [@@account]

type metadata = { authority : bytes }

type status = Ready | Frozen of int

let error_insufficient_funds = 65537

let entrypoint authority amount =
  if authority.is_signer then
    if authority.is_writable then amount else error_insufficient_funds
  else error_insufficient_funds
