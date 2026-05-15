let entrypoint _ =
  let flag = ref false in
  let _ = flag := true in
  if !flag then 1 else 0
