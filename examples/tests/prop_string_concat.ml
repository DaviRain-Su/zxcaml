let string seed = ("abc", seed + 1)

let%test_prop "concat associativity" string = fun s ->
  String.length ((s ^ "x") ^ "y") = String.length (s ^ ("x" ^ "y"))
