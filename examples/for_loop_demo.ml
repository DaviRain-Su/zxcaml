(* ADR-015 option D demo: `for i = lo to hi do body done` is accepted by the
   frontend and desugared into a self-recursive `let rec` whose back-edge tail
   call is lowered to `while (true)` in generated Zig.

   Caveat: until ADR-015 options B (`array`) and C (`ref`) land, the loop body
   cannot mutate, so this example mostly demonstrates that the surface syntax
   is accepted and that the desugared loop runs without panicking. *)
let entrypoint _ =
  let _ = for i = 1 to 5 do () done in
  let _ = for j = 3 downto 0 do () done in
  0
