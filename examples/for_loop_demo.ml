(* ADR-015 option D demo: `for i = lo to hi do body done` is accepted by the
   frontend and desugared into a self-recursive `let rec` whose back-edge tail
   call is lowered to `while (true)` in generated Zig.

   Mutable loop bodies are covered by `ref_loop_demo.ml` and
   `mutable_state_stress.ml`; this file stays intentionally side-effect-light
   so the report golden remains easy to read. *)
let entrypoint _ =
  let _ = for i = 1 to 5 do () done in
  let _ = for j = 3 downto 0 do () done in
  0
