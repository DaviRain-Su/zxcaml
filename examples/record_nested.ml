type person = { name : string; age : int }
type outer = { person : person; score : int }

let entrypoint _ =
  let alice = { name = "alice"; age = 30 } in
  let outer = { person = alice; score = 100 } in
  let _ = outer.person.name in
  outer.person.age
