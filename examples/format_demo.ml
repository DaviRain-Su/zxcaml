(* Demonstrates the bundled-stdlib additions wired through the Zig pipeline:
     - Bytes.equal / Bytes.compare
     - Format.int_to_string / Format.hex_of_int
     - Option.map / Option.bind / Option.fold        (R6b.3 inline lowering)
     - Result.map / Result.bind / Result.map_error   (R6b.3 inline lowering)

   The remaining higher-order helpers (Bytes.iter, Bytes.iteri,
   Bytes.fold_left, List.iter) are still tracked separately under R6b.4
   and are intentionally not exercised here so this example continues to
   run under both `omlz run` (interpreter) and `omlz build --target=native`. *)

let entrypoint _ =
  let n_str = Format.int_to_string 42 in
  let hex_str = Format.hex_of_int 4 0xbeef in
  let hex_pad = Format.hex_of_int 8 0x2a in
  let a = Bytes.of_string "hello" in
  let b = Bytes.of_string "hello" in
  let c = Bytes.of_string "world" in
  let eq_same = Bytes.equal a b in
  let eq_diff = Bytes.equal a c in
  let cmp_eq = Bytes.compare a b in
  let cmp_lt = Bytes.compare a c in
  let cmp_gt = Bytes.compare c a in
  (* Higher-order Option helpers (lowered to Match at Core IR time). *)
  let opt_map_result = Option.map (fun x -> x + 1) (Some 41) in
  let opt_mapped =
    match opt_map_result with
    | Some v -> v
    | None -> 0
  in
  let opt_bind_result = Option.bind (Some 10) (fun x -> if x > 0 then Some (x * 2) else None) in
  let opt_bound =
    match opt_bind_result with
    | Some v -> v
    | None -> 0
  in
  let opt_folded = Option.fold ~none:0 ~some:(fun x -> x + 1) (Some 41) in
  (* Higher-order Result helpers (lowered to Match at Core IR time). *)
  let res_map_result = Result.map (fun x -> x + 1) (Ok 41) in
  let res_mapped =
    match res_map_result with
    | Ok v -> v
    | Error _ -> 0
  in
  let res_bind_result = Result.bind (Ok 10) (fun x -> Ok (x * 2)) in
  let res_bound =
    match res_bind_result with
    | Ok v -> v
    | Error _ -> 0
  in
  let res_map_err_result = Result.map_error (fun code -> code + 1) (Error 41) in
  let res_map_err_remapped =
    match res_map_err_result with
    | Ok _ -> 0
    | Error e -> e
  in
  assert (String.length n_str = 2);
  assert (String.length hex_str = 4);
  assert (String.length hex_pad = 8);
  assert (eq_same);
  assert (if eq_diff then false else true);
  assert (cmp_eq = 0);
  assert (cmp_lt < 0);
  assert (cmp_gt > 0);
  assert (opt_mapped = 42);
  assert (opt_bound = 20);
  assert (opt_folded = 42);
  assert (res_mapped = 42);
  assert (res_bound = 20);
  assert (res_map_err_remapped = 42);
  0
