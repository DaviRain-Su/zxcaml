let check_positive x =
  assert (x > 0);
  x

let entrypoint _ =
  assert true;
  let ok = true in
  assert ok;
  let x = check_positive 5 in
  let y = if x > 3 then (assert (x = 5); x + 5) else 0 in
  let z =
    match Some y with
    | Some n ->
        assert (n > 0);
        n
    | None -> 0
  in
  assert (ok && z = 10);
  assert (ok || false);
  z + 32
