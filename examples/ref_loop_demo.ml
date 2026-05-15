let entrypoint _ =
  let acc = ref 0 in
  let _ = for i = 1 to 10 do
    acc := !acc + i
  done in
  !acc
