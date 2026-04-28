(* Demonstrates a P2 parameterized ADT and matching payload constructors. *)

type 'a option = None | Some of 'a
(* 'a is a type parameter; Some carries one payload whose type is chosen at use sites. *)

let entrypoint _ =
  let some_value =
    (* Some 21 constructs the payload variant, and Some x binds that payload. *)
    match Some 21 with
    | Some x -> x
    | None -> 0
  in
  let none_value =
    (* None is a nullary constructor, so it has no payload to bind. *)
    match None with
    | Some x -> x
    | None -> 0
  in
  if some_value + none_value = 21 then 0 else 1
