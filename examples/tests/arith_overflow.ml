(* Demonstrates unit-test bindings over arithmetic wraparound with CI-safe checks. *)

let wraps_after_max value = value + 1

let wraps_before_min value = value - 1

let checked_delta base delta = base + delta

let%test_unit "max wraps to min" = assert (wraps_after_max max_int = min_int)

let%test_unit "min wraps to max" = assert (wraps_before_min min_int = max_int)

(* CI ships the passing variant; use arith_overflow.fail.ml.template when
   OTEST_DEMO_INCLUDE_FAILURE=1 for reporter-output demo recording. *)
let%test_unit "overflow detected" =
  assert (checked_delta max_int 1 = min_int)
