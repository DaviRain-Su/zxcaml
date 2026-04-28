let entrypoint _ =
  let ys = List.map (fun x -> x + 1) [ 1; 2; 3 ] in
  match ys with
  | a :: b :: c :: [] when a = 2 ->
      if b = 3 then if c = 4 then 0 else 1 else 1
  | _ -> 1
