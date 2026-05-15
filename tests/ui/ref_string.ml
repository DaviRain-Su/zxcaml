let entrypoint _ =
  let r = ref "hello" in
  let _ = r := "world" in
  0
