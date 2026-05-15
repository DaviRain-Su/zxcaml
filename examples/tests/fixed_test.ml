let%test_unit "fixed constructors and rounding" =
  assert (Fixed.scale = 1000000);
  assert (Fixed.to_scaled (Fixed.of_int 3) = 3000000);
  assert (Fixed.to_int_trunc (Fixed.of_scaled 1750000) = 1);
  assert (Fixed.to_int_floor (Fixed.of_scaled 1750000) = 1);
  assert (Fixed.to_int_ceil (Fixed.of_scaled 1000001) = 2);
  assert (Fixed.to_int_round (Fixed.of_scaled 1500000) = 2)

let%test_unit "fixed arithmetic" =
  let one = Fixed.of_int 1 in
  let two = Fixed.of_int 2 in
  let one_half = Fixed.of_scaled 1500000 in
  assert (Fixed.add one two = Fixed.of_int 3);
  assert (Fixed.sub two one = one);
  assert (Fixed.mul one_half two = Fixed.of_int 3);
  assert (Fixed.div (Fixed.of_int 3) two = one_half);
  assert (Fixed.ratio 3 2 = one_half);
  assert (Fixed.apply 10000 one_half = 15000)

let%test_unit "amount basis points" =
  assert (Fixed.bps 30 = Fixed.of_scaled 3000);
  assert (Amount.fee_bps 10000 30 = 30);
  assert (Amount.discount_bps 10000 30 = 9970);
  assert (Amount.premium_bps 10000 30 = 10030);
  assert (Amount.apply_rate 9970 (Fixed.of_int 2) = 19940)
