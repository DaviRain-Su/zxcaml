external promise_create : bytes -> int = "near.promise_create"

let entrypoint input =
  promise_create input
