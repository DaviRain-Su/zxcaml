type 'a box = Box of 'a

let entrypoint _ =
  let flag = 1 = 1 in
  match Box flag with
  | Box boxed_flag -> if boxed_flag then 0 else 1
