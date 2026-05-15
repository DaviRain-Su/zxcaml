(* ADR-015 option D demo: `while cond do body done` is accepted by the
   frontend and desugared into a unit-argument self-recursive `let rec` whose
   tail call is lowered to `while (true)` in generated Zig.

   Mutable loop conditions/bodies are covered by `mutable_state_stress.ml`;
   this file keeps a literal `false` condition so the report golden remains a
   compact unknown-loop smoke. *)
let entrypoint _ =
  let _ = while false do () done in
  0
