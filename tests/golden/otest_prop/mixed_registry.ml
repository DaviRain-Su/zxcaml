let gen = ()
let%test_unit "unit passes" = ()
let%test_prop "prop passes" gen = fun x -> assert (x = x)
