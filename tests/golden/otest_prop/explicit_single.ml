let gen = ()
let%test_prop "explicit single" gen x = assert (x = x)
