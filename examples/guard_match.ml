type branch = A of int | B of int | C | D | E

let entrypoint _input =
  let guarded =
    match A 17 with
    | A v when v > 100 -> 1
    | A v when v > 10 -> v + 20
    | B v when v = 0 -> v
    | C -> 3
    | _ -> 4
  in
  let fallthrough =
    match A 5 with
    | A v when v > 10 -> v
    | A _ -> 5
    | _ -> 0
  in
  let catch_all =
    match E with
    | A v when v > 0 -> v
    | B v -> v
    | _ -> 0
  in
  guarded + fallthrough + catch_all
