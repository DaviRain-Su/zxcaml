let gen = ()
let%test_prop "parenthesized generator" (gen) = fun x -> assert (x = x)
