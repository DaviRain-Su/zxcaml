let before = 41
let%test_unit "middle" = assert ((before + 1) = 42)
let after _ = before + 1
