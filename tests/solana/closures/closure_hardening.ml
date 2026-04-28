let closure_adt_ok ignored =
  let opt = Some 5 in
  let f =
    match opt with Some v when v > 0 -> fun y -> y + v | _ -> fun y -> y
  in
  f 7 + ignored

let list_map_ok ignored =
  let ys = List.map (fun x -> x + 1) [ 1; 2; 3 ] in
  match ys with
  | a :: b :: c :: [] when a = 2 ->
      if b = 3 then if c = 4 then c + ignored else 0 else 0
  | _ -> ignored

let multi_env_ok ignored =
  let a = 2 in
  let b = 3 in
  let f = fun x -> (x + a) * b in
  f 4 + ignored

let nested_closure_ok ignored =
  let f =
    fun x ->
      let g = fun y -> x + y in
      g
  in
  let h = f 4 in
  h 5 + ignored

let entrypoint _ =
  let a = closure_adt_ok 0 in
  let b = list_map_ok 0 in
  let c = multi_env_ok 0 in
  let d = nested_closure_ok 0 in
  if a = 12 then
    if b = 4 then if c = 18 then if d = 9 then 0 else 1 else 1 else 1
  else 1
