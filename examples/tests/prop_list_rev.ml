let int seed = seed

let list_of element max_len =
  fun seed ->
    if max_len = 0 then ([], seed + 1) else ([ seed; seed + 1 ], seed + 2)

let%test_prop "rev rev = id" (list_of int 10) = fun xs ->
  List.length (List.rev (List.rev xs)) = List.length xs
