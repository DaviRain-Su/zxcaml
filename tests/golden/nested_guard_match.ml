let entrypoint _input =
  let x = Some (Some 42) in
  match x with
  | Some (Some v) when v > 40 -> v
  | Some _ -> 1
  | None -> 0
