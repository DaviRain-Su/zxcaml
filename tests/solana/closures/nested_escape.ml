let entrypoint _ =
  let f =
    fun x ->
      let g = fun y -> x + y in
      g
  in
  let h = f 4 in
  if h 5 = 9 then 0 else 1
