type 'a either = Left of 'a | Right of 'a

let entrypoint _input =
  match Some (Left 42) with
  | Some (Left v) -> v
  | Some (Right v) -> v
  | None -> 0
