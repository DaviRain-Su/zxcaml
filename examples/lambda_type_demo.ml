(* R8 demo — lambda parameter types are now inferred by the OCaml frontend
   and threaded through to the Core IR lowerer. The three scenarios below
   exercise the three interesting cases of the wire 1.3 plumbing:

   1. Concrete primitive type (int) — wire emits `(ty (type-ref int))` and
      the lowerer maps it straight to `Ty.Int`.
   2. String / bytes payload — wire emits `(ty (type-ref string))` and the
      lowerer no longer falls back to `Ty.Int`.
   3. Polymorphic / unresolved type — wire emits `(ty (any))`, the bridge
      maps it to `null`, and the lowerer falls back to the existing
      structural heuristics. *)

let add_one (n : int) = n + 1

let echo_bytes (b : bytes) =
  if Bytes.length b > 0 then 0 else 1

(* `identity` is intentionally polymorphic; with no usage hints, the wire
   type expression collapses to `(any)` and the lowerer keeps its legacy
   heuristic-based behavior. *)
let identity x = x

let entrypoint _input =
  let a = add_one 1 in
  let b = echo_bytes (Bytes.of_string "hi") in
  let c = identity 0 in
  if (a = 2) && (b = 0) && (c = 0) then 0 else 1
