(* ADR-015 option D demo: `while cond do body done` is accepted by the
   frontend and desugared into a unit-argument self-recursive `let rec` whose
   tail call is lowered to `while (true)` in generated Zig.

   Caveat: until ADR-015 options B (`array`) and C (`ref`) land, the loop body
   cannot mutate, so the only condition that terminates without mutation is a
   literal `false`. This example exists to demonstrate that the surface
   syntax is accepted and the desugared form runs to completion. *)
let entrypoint _ =
  let _ = while false do () done in
  0
