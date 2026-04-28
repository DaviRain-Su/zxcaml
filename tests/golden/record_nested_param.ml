type person = { name : string; age : int }
type outer = { person : person; score : int }
type 'a box = { value : 'a }

let entrypoint _ =
  let alice = { name = "alice"; age = 30 } in
  let outer = { person = alice; score = 100 } in
  let boxed = { value = outer.person.age } in
  boxed.value
