let id n =
  let value = n in
  value

let entrypoint _input =
  let stack_local = 1 + 2 in
  let arena_local = 4 in
  let _consume = stack_local + id arena_local in
  0
