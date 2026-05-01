let check_positive x =
  assert (x > 0);
  x

let entrypoint _ = check_positive 5
