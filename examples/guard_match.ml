(* Demonstrates P2 guarded match arms and wildcard fallback behavior. *)

type branch = A of int | B of int | C | D | E
(* Payload constructors A/B carry ints; C/D/E are nullary constructors. *)

let entrypoint _input =
  let guarded =
    match A 17 with
    (* A guard after when must be true before this arm can fire. *)
    | A v when v > 100 -> 1
    (* If the first guard is false, matching falls through to later arms. *)
    | A v when v > 10 -> v + 20
    | B v when v = 0 -> v
    | C -> 3
    (* _ catches any constructor not matched by earlier arms. *)
    | _ -> 4
  in
  let fallthrough =
    match A 5 with
    | A v when v > 10 -> v
    | A _ -> 5
    | _ -> 0
  in
  let catch_all =
    match E with
    | A v when v > 0 -> v
    | B v -> v
    | _ -> 0
  in
  guarded + fallthrough + catch_all
