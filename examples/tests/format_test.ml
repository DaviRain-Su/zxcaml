(* Smoke tests for the non-HOF stdlib helpers wired through the Zig
   pipeline by R6b.2, plus the higher-order Option/Result helpers added
   by R6b.3 (inline-expanded at Core IR lowering time):
     - Format.int_to_string : int -> string
     - Format.hex_of_int    : int -> int -> string
     - Bytes.equal          : bytes -> bytes -> bool
     - Bytes.compare        : bytes -> bytes -> int
     - Option.map           : ('a -> 'b) -> 'a option -> 'b option
     - Option.bind          : 'a option -> ('a -> 'b option) -> 'b option
     - Option.fold          : none:'b -> some:('a -> 'b) -> 'a option -> 'b
     - Result.map           : ('a -> 'b) -> ('a, 'e) result -> ('b, 'e) result
     - Result.bind          : ('a, 'e) result -> ('a -> ('b, 'e) result)
                              -> ('b, 'e) result
     - Result.map_error     : ('e -> 'f) -> ('a, 'e) result -> ('a, 'f) result

   The remaining higher-order helpers (Bytes.iter, Bytes.iteri,
   Bytes.fold_left, List.iter) still surface as `UnboundVariable` from
   the Zig pipeline and are tracked by R6b.4. Richer end-to-end
   coverage for those lives in `stdlib/core_tests.ml`, which the
   upstream OCaml oracle compiles and executes. *)

let%test_unit "Format.int_to_string returns expected lengths" =
  assert (String.length (Format.int_to_string 0) = 1);
  assert (String.length (Format.int_to_string 42) = 2);
  assert (String.length (Format.int_to_string 1000) = 4)

let%test_unit "Format.hex_of_int zero-pads to width" =
  assert (String.length (Format.hex_of_int 4 0xbeef) = 4);
  assert (String.length (Format.hex_of_int 8 0x2a) = 8);
  assert (String.length (Format.hex_of_int 2 0x0) = 2)

let%test_unit "Bytes.equal compares contents" =
  let a = Bytes.of_string "hello" in
  let b = Bytes.of_string "hello" in
  let c = Bytes.of_string "world" in
  assert (Bytes.equal a b);
  assert (if Bytes.equal a c then false else true)

let%test_unit "Bytes.compare returns -1/0/1" =
  let a = Bytes.of_string "hello" in
  let b = Bytes.of_string "hello" in
  let c = Bytes.of_string "world" in
  assert (Bytes.compare a b = 0);
  assert (Bytes.compare a c < 0);
  assert (Bytes.compare c a > 0)

let%test_unit "Option.map increments inner value" =
  let mapped = Option.map (fun x -> x + 1) (Some 41) in
  let value =
    match mapped with
    | Some v -> v
    | None -> 0
  in
  assert (value = 42)

let%test_unit "Option.bind chains an option-returning continuation" =
  let bound = Option.bind (Some 10) (fun x -> if x > 0 then Some (x * 2) else None) in
  let value =
    match bound with
    | Some v -> v
    | None -> 0
  in
  assert (value = 20)

let%test_unit "Option.fold returns some-branch for Some values" =
  let folded = Option.fold ~none:0 ~some:(fun x -> x + 1) (Some 41) in
  assert (folded = 42)

let%test_unit "Option.fold returns none-branch for None" =
  let folded = Option.fold ~none:7 ~some:(fun x -> x + 1) None in
  assert (folded = 7)

let%test_unit "Result.map increments Ok value" =
  let mapped = Result.map (fun x -> x + 1) (Ok 41) in
  let value =
    match mapped with
    | Ok v -> v
    | Error _ -> 0
  in
  assert (value = 42)

let%test_unit "Result.bind chains a result-returning continuation" =
  let bound = Result.bind (Ok 10) (fun x -> Ok (x * 2)) in
  let value =
    match bound with
    | Ok v -> v
    | Error _ -> 0
  in
  assert (value = 20)

let%test_unit "Result.map_error remaps Error payload" =
  let mapped = Result.map_error (fun code -> code + 1) (Error 41) in
  let value =
    match mapped with
    | Ok _ -> 0
    | Error e -> e
  in
  assert (value = 42)
