let entrypoint _ =
  let r = ref 10 in
  let _ = r := 25 in
  !r
