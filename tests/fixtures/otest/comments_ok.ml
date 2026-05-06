(* Documents let%test_unit syntax *)
(* outer (* inner has let%foo *) closes *)
let%test_unit "real" = ()
let entrypoint _ = ()
