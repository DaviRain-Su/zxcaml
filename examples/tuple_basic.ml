type packed = Packed of int * bool * int

let entrypoint _input =
  let triple = (1, true, 42) in
  match triple with
  | (a, flag, c) ->
      let payload = Packed (a, flag, c) in
      match payload with
      | Packed (x, keep, y) -> if keep then x + y else 0
