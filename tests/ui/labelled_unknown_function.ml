let entrypoint _ = ListLabels.fold_left ~init:0 ~f:(fun acc x -> acc + x) [1; 2; 3]
