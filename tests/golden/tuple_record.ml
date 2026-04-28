type person = { name : string; age : int }

let entrypoint _ =
  let _ = (1, true, 42) in
  let t = (1, 2) in
  let r = { name = "alice"; age = 30 } in
  let r2 = { r with age = 31 } in
  let _ = r.name in
  (fst t) + r2.age
