(* Upstream OCaml sanity tests for the ZxCaml core stdlib subset.

   These tests intentionally exercise the real definitions in core.ml with
   ordinary ADT patterns, higher-order functions, and closures. *)

open Core

let () =
  assert (List.length [ 1; 2; 3 ] = 3);
  assert (List.map (fun x -> x + 1) [ 1; 2; 3 ] = [ 2; 3; 4 ]);
  assert (List.filter (fun x -> x > 1) [ 1; 2; 3 ] = [ 2; 3 ]);
  assert (List.fold_left (fun acc x -> acc + x) 0 [ 1; 2; 3 ] = 6);
  assert (List.rev [ 1; 2; 3 ] = [ 3; 2; 1 ]);
  assert (List.append [ 1; 2 ] [ 3; 4 ] = [ 1; 2; 3; 4 ]);
  assert (List.hd [ 9; 8; 7 ] = 9);
  assert (List.tl [ 9; 8; 7 ] = [ 8; 7 ]);
  assert (Option.is_none None);
  assert (not (Option.is_none (Some 1)));
  assert (Option.is_some (Some 1));
  assert (not (Option.is_some None));
  assert (Option.value None 42 = 42);
  assert (Option.value (Some 7) 42 = 7);
  assert (Option.get (Some 5) = 5);
  assert (Option.map (fun x -> x + 2) (Some 3) = Some 5);
  assert (Option.bind (Some 3) (fun x -> Some (x + 4)) = Some 7);
  assert (Result.is_ok (Ok 1));
  assert (not (Result.is_ok (Error 2)));
  assert (Result.is_error (Error 2));
  assert (not (Result.is_error (Ok 1)));
  assert (Result.ok (Ok 11) = Some 11);
  assert (Result.ok (Error 12) = None);
  assert (Result.error (Ok 11) = None);
  assert (Result.error (Error 12) = Some 12);
  assert (Result.map (fun x -> x + 1) (Ok 4) = Ok 5);
  assert (Result.bind (Ok 4) (fun x -> Ok (x + 1)) = Ok 5)
