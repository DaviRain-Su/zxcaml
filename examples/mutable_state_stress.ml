(* R12 mutable-state hardening smoke: arrays, refs, for/downto loops, and
   while loops must agree across interpreter, native Zig, and BPF. *)

let entrypoint _ =
  let values = Array.make 6 0 in
  let total = ref 0 in
  let i = ref 0 in
  let _ =
    while !i < Array.length values do
      let next = (!i + 1) * (!i + 1) in
      let _ = values.(!i) <- next in
      let _ = total := !total + next in
      i := !i + 1
    done
  in
  let weighted = ref 0 in
  let _ =
    for j = 0 to Array.length values - 1 do
      weighted := !weighted + ((j + 1) * values.(j))
    done
  in
  let descending = ref 0 in
  let _ =
    for k = Array.length values - 1 downto 0 do
      descending := !descending + values.(k)
    done
  in
  let ok = ref false in
  let _ = ok := !total = 91 in
  let _ = ok := !ok && !weighted = 441 in
  let _ = ok := !ok && !descending = !total in
  let _ = ok := !ok && values.(0) = 1 in
  let _ = ok := !ok && values.(5) = 36 in
  assert !ok;
  0
