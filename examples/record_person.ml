type person = { name : string; age : int }

let entrypoint _input =
  let alice = { name = "alice"; age = 30 } in
  let birthday = { alice with age = alice.age + 1 } in
  match birthday with
  | { name; age } ->
      let _ = name in
      age
