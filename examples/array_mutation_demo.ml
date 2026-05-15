(* ADR-015 R9.1 + R9.2: read-only int array surface plus in-place
   writes via [a.(i) <- v] / [Array.set] and [Array.make N init]. *)

let entrypoint _ =
  let a = Array.make 4 0 in
  let _ = a.(0) <- 10 in
  let _ = a.(1) <- 20 in
  let _ = a.(2) <- 30 in
  let _ = a.(3) <- 40 in
  let b = [| 1; 2; 3 |] in
  let _ = Array.set b 0 100 in
  Array.length a + Array.get a 2 + b.(0)
