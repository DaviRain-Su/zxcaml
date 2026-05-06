(* Demonstrates unit-test bindings over list length, reverse, and map helpers. *)

let rec list_ops_length xs =
  match xs with [] -> 0 | _ :: rest -> 1 + list_ops_length rest

let rec list_ops_rev_acc xs acc =
  match xs with [] -> acc | head :: rest -> list_ops_rev_acc rest (head :: acc)

let list_ops_rev xs = list_ops_rev_acc xs []

let rec list_ops_map f xs =
  match xs with [] -> [] | head :: rest -> f head :: list_ops_map f rest

let rec int_list_eq left right =
  match left with
  | [] -> (match right with [] -> true | _ -> false)
  | left_head :: left_tail -> (
      match right with
      | [] -> false
      | right_head :: right_tail ->
          if left_head = right_head then int_list_eq left_tail right_tail else false)

let triple value = value * 3

let sample = [ 1; 2; 3; 4 ]

let%test_unit "list_ops length" = assert (list_ops_length sample = 4)

let%test_unit "list_ops rev" =
  assert (int_list_eq (list_ops_rev sample) [ 4; 3; 2; 1 ])

let%test_unit "list_ops map" =
  assert (int_list_eq (list_ops_map triple sample) [ 3; 6; 9; 12 ])
