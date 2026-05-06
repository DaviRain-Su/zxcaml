let gen = ()
let%test_prop "identity" gen = fun x -> assert (x = x)
