let twice x = x + x

let bool_to_int flag = if flag then 1 else 0

let entrypoint _input =
  let base = twice 20 in
  base + bool_to_int (base = 40) + 1
