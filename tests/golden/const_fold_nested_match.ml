let v = match Some (Some 1) with Some x -> (match x with Some y -> y | None -> 0) | None -> 0
