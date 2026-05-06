let int seed = (seed, seed + 1)

let%test_prop "add commutative" int = fun x -> x + 7 = 7 + x
