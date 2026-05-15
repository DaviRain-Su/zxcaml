(* fixture used by hover Python harness *)
let identity x = x

let rec factorial n =
  if n <= 1 then 1 else n * factorial (n - 1)

let length_demo xs = List.length xs

let entrypoint _ = factorial (length_demo [1; 2; 3])
