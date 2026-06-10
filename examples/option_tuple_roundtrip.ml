(* CR-14 regression: an option-of-tuple value crossing a function boundary.
   Native/BPF codegen must intern the tuple shape as one named struct so both
   functions agree on the type, and the [None] branch must adopt the concrete
   [(bytes * int) option] instantiation instead of the [int option] default. *)
let pick flag = if flag then Some (Bytes.of_string "k", 254) else None

let entrypoint (_a : account) (_data : bytes) =
  match pick true with
  | Some (_addr, bump) -> bump
  | None -> 255
