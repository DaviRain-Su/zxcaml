type 'a option = None | Some of 'a

let entrypoint _ =
  let some_value =
    match Some 21 with
    | Some x -> x
    | None -> 0
  in
  let none_value =
    match None with
    | Some x -> x
    | None -> 0
  in
  if some_value + none_value = 21 then 0 else 1
