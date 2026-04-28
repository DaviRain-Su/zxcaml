let entrypoint _input =
  (* Exercise stdlib List closures over the same list pipeline. *)
  let doubled = List.map (fun x -> x * 2) [ 1; 2; 3; 4 ] in
  let large = List.filter (fun x -> x > 2) [ 1; 2; 3; 4 ] in
  let mapped_score =
    match doubled with
    | _ :: second :: _ -> second
    | _ -> 0
  in
  let filtered_score =
    match large with
    | first :: second :: [] -> first + second
    | _ -> 0
  in
  mapped_score + filtered_score
  + List.fold_left (fun acc x -> acc + x) 0 [ 1; 2; 3; 4 ]
