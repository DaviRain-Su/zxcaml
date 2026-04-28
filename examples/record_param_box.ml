type 'a box = { value : 'a }

let entrypoint _ =
  let flag = 1 = 1 in
  let boxed = { value = flag } in
  if boxed.value then 0 else 1
