(* Test bitwise operations: land, lor, lxor, lsl, lsr, lnot.
   Returns 0 on success (determinism corpus expects native ≡ interpreter). *)

let lo_byte value = (value land 0xFF)
let hi_byte value = ((value lsr 8) land 0xFF)

let entrypoint _ =
  let a = 0xFF land 0x0F in     (* 15 *)
  let b = 0xF0 lor 0x0F in      (* 255 *)
  let c = 0xFF lxor 0xFF in     (* 0 *)
  let d = 1 lsl 8 in            (* 256 *)
  let e = 256 lsr 4 in          (* 16 *)
  let _ = lnot 0 in             (* -1 *)
  let lo = lo_byte 0x1234 in    (* 0x34 = 52 *)
  let hi = hi_byte 0x1234 in    (* 0x12 = 18 *)
  let check = a + b + c + d + e + lo + hi in
  if check = 612 then 0 else 1
