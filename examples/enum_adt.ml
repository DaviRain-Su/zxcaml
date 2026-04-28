(* Demonstrates a P2 user-defined enum ADT plus exhaustive constructor matches. *)

type color = Red | Green | Blue
(* Nullary constructors carry no payload; their order defines stable tags. *)

let entrypoint _ =
  (* Matching a constructor chooses the arm with the same constructor name. *)
  let red =
    match Red with
    | Red -> 1
    | Green -> 0
    | Blue -> 0
  in
  let green =
    (* Exhaustive matches list every constructor of the ADT. *)
    match Green with
    | Red -> 0
    | Green -> 2
    | Blue -> 0
  in
  let blue =
    match Blue with
    | Red -> 0
    | Green -> 0
    | Blue -> 3
  in
  let total = red + green + blue in
  if total = 6 then 0 else 1
