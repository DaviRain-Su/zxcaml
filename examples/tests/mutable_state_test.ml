let%test_unit "array mutation and length" =
  let a = Array.make 5 0 in
  let _ = a.(0) <- 3 in
  let _ = a.(1) <- 5 in
  let _ = Array.set a 2 7 in
  assert (Array.length a = 5);
  assert (a.(0) + a.(1) + Array.get a 2 = 15)

let%test_unit "refs drive while loop" =
  let i = ref 0 in
  let acc = ref 0 in
  let _ =
    while !i < 6 do
      let _ = acc := !acc + !i in
      i := !i + 1
    done
  in
  assert (!acc = 15);
  assert (!i = 6)

let%test_unit "arrays refs and for loops compose" =
  let a = Array.make 4 1 in
  let total = ref 0 in
  let _ =
    for i = 0 to Array.length a - 1 do
      let value = (i + 1) * 10 in
      let _ = a.(i) <- value in
      total := !total + value
    done
  in
  let reverse = ref 0 in
  let _ =
    for i = Array.length a - 1 downto 0 do
      reverse := !reverse + a.(i)
    done
  in
  assert (!total = 100);
  assert (!reverse = !total);
  assert (a.(0) = 10);
  assert (a.(3) = 40)

let%test_unit "bool refs preserve branch state" =
  let seen_large = ref false in
  let values = [| 2; 4; 8; 16 |] in
  let _ =
    for i = 0 to Array.length values - 1 do
      if values.(i) > 10 then seen_large := true else ()
    done
  in
  assert !seen_large
