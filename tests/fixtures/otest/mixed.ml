let base = 40

let%test_unit "foo passes" = assert (base + 2 = 42)

let%test_unit "bar fails" = assert (base = 0)
