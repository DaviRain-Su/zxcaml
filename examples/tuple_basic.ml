(* Demonstrates P2 tuple construction/destructuring and tuple payload constructors. *)

type packed = Packed of int * bool * int
(* Constructor payload syntax int * bool * int is a three-field product. *)

let entrypoint _input =
  (* Parenthesized comma syntax constructs a tuple value. *)
  let triple = (1, true, 42) in
  match triple with
  (* Tuple patterns destructure fields by position and bind local names. *)
  | (a, flag, c) ->
      let payload = Packed (a, flag, c) in
      match payload with
      (* ADT payload patterns use the same positional tuple destructuring. *)
      | Packed (x, keep, y) -> if keep then x + y else 0
