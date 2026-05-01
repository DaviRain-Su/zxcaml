let check_positive x =
  assert (x > 0);
  x

let entrypoint _ =
  let x = check_positive 5 in
  assert (x = 5);
  x
