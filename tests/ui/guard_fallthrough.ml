let entrypoint _input =
  let x = Some 7 in
  match x with
  | Some v when v > 10 -> 1
  | Some _ -> 2
  | None -> 3
