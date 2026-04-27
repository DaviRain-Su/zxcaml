(* Spike α input program.
   Exercises let-binding, ADT (option), and match — the three
   constructs we need to confirm appear in the Typedtree dump. *)

let describe (x : int option) =
  match x with
  | None -> "none"
  | Some n ->
      let doubled = n + n in
      if doubled > 0 then "positive" else "non-positive"

let _ = describe (Some 42)
