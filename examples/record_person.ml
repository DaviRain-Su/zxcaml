(* Demonstrates P2 record construction, field access, functional update, and patterns. *)

type person = { name : string; age : int }
(* Record declarations name each field and its type. *)

let entrypoint _input =
  (* Record literals assign values by field name rather than position. *)
  let alice = { name = "alice"; age = 30 } in
  (* Functional update copies alice and replaces age; alice.age reads a field. *)
  let birthday = { alice with age = alice.age + 1 } in
  match birthday with
  (* Record patterns bind fields by name; { name; age } is shorthand. *)
  | { name; age } ->
      let _ = name in
      age
