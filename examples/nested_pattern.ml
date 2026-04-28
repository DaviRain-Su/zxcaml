(* Demonstrates P2 nested constructor patterns inside a match arm. *)

type 'a either = Left of 'a | Right of 'a
(* The payload type parameter lets either wrap any accepted value type. *)

let entrypoint _input =
  (* Some (Left 42) nests one constructor value inside another. *)
  match Some (Left 42) with
  (* This single pattern checks both outer Some and inner Left, then binds v. *)
  | Some (Left v) -> v
  | Some (Right v) -> v
  (* The final arm covers the nullary None constructor. *)
  | None -> 0
