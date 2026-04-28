(* Demonstrates a P2 recursive parameterized ADT and recursive-shape matches. *)

type 'a tree = Leaf of 'a | Node of 'a tree * 'a tree
(* Node refers back to 'a tree, so values can contain arbitrarily nested subtrees. *)

let entrypoint _ =
  (* Constructor arguments build nested tree values. *)
  let tree = Node (Leaf 1, Node (Leaf 2, Leaf 3)) in
  let total =
    match tree with
    | Leaf x -> x
    (* Node (left, right) destructures the two recursive child payloads. *)
    | Node (left, right) ->
        let left_total =
          match left with
          | Leaf x -> x
          | Node (_, _) -> 0
        in
        let right_total =
          match right with
          | Leaf x -> x
          | Node (right_left, right_right) ->
              let right_left_total =
                match right_left with
                | Leaf x -> x
                | Node (_, _) -> 0
              in
              let right_right_total =
                match right_right with
                | Leaf x -> x
                | Node (_, _) -> 0
              in
              right_left_total + right_right_total
        in
        left_total + right_total
  in
  if total = 6 then 0 else 1
