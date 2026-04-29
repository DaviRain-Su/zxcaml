(* Upstream OCaml sanity tests for the ZxCaml core stdlib subset.

   These tests intentionally exercise the real definitions in core.ml with
   ordinary ADT patterns, higher-order functions, and closures. *)

open Core

let () =
  assert (List.length [ 1; 2; 3 ] = 3);
  assert (List.map (fun x -> x + 1) [ 1; 2; 3 ] = [ 2; 3; 4 ]);
  assert (List.filter (fun x -> x > 1) [ 1; 2; 3 ] = [ 2; 3 ]);
  assert (List.fold_left (fun acc x -> acc + x) 0 [ 1; 2; 3 ] = 6);
  assert (List.rev [ 1; 2; 3 ] = [ 3; 2; 1 ]);
  assert (List.append [ 1; 2 ] [ 3; 4 ] = [ 1; 2; 3; 4 ]);
  assert (List.hd [ 9; 8; 7 ] = 9);
  assert (List.tl [ 9; 8; 7 ] = [ 8; 7 ]);
  assert (Option.is_none None);
  assert (not (Option.is_none (Some 1)));
  assert (Option.is_some (Some 1));
  assert (not (Option.is_some None));
  assert (Option.value None 42 = 42);
  assert (Option.value (Some 7) 42 = 7);
  assert (Option.get (Some 5) = 5);
  assert (Option.map (fun x -> x + 2) (Some 3) = Some 5);
  assert (Option.bind (Some 3) (fun x -> Some (x + 4)) = Some 7);
  assert (Result.is_ok (Ok 1));
  assert (not (Result.is_ok (Error 2)));
  assert (Result.is_error (Error 2));
  assert (not (Result.is_error (Ok 1)));
  assert (Result.ok (Ok 11) = Some 11);
  assert (Result.ok (Error 12) = None);
  assert (Result.error (Ok 11) = None);
  assert (Result.error (Error 12) = Some 12);
  assert (Result.map (fun x -> x + 1) (Ok 4) = Ok 5);
  assert (Result.bind (Ok 4) (fun x -> Ok (x + 1)) = Ok 5);
  let int_compare left right =
    if left < right then -1 else if left > right then 1 else 0
  in
  let empty_map = Map.empty int_compare in
  assert (Map.size empty_map = 0);
  assert (Map.to_list empty_map = []);
  assert (Map.find 1 empty_map = None);
  assert (not (Map.mem 1 empty_map));
  let singleton_map = Map.singleton 3 "three" int_compare in
  assert (Map.size singleton_map = 1);
  assert (Map.find 3 singleton_map = Some "three");
  assert (Map.to_list singleton_map = [ (3, "three") ]);
  let map_with_two =
    Map.add 2 "two" (Map.add 1 "one" (Map.add 3 "three" empty_map))
  in
  assert (Map.size map_with_two = 3);
  assert (Map.to_list map_with_two = [ (1, "one"); (2, "two"); (3, "three") ]);
  assert (Map.find 2 map_with_two = Some "two");
  assert (Map.mem 1 map_with_two);
  assert (not (Map.mem 4 map_with_two));
  let overwritten_map = Map.add 2 "TWO" map_with_two in
  assert (Map.size overwritten_map = 3);
  assert (Map.find 2 overwritten_map = Some "TWO");
  assert (Map.find 2 map_with_two = Some "two");
  let removed_map = Map.remove 2 overwritten_map in
  assert (Map.size removed_map = 2);
  assert (Map.find 2 removed_map = None);
  assert (Map.find 2 overwritten_map = Some "TWO");
  assert (Map.to_list (Map.remove 9 removed_map) = Map.to_list removed_map);
  let rec add_map_range n map =
    if n = 0 then map else add_map_range (n - 1) (Map.add n (n * 10) map)
  in
  let rec check_map_range n map =
    if n = 0 then ()
    else (
      assert (Map.find n map = Some (n * 10));
      check_map_range (n - 1) map)
  in
  let hundred_map = add_map_range 100 empty_map in
  assert (Map.size hundred_map = 100);
  check_map_range 100 hundred_map;
  let empty_set = Set.empty int_compare in
  assert (Set.size empty_set = 0);
  assert (Set.to_list empty_set = []);
  assert (not (Set.mem 1 empty_set));
  let singleton_set = Set.singleton 3 int_compare in
  assert (Set.size singleton_set = 1);
  assert (Set.mem 3 singleton_set);
  assert (Set.to_list singleton_set = [ 3 ]);
  let set_with_three = Set.add 2 (Set.add 1 (Set.add 3 empty_set)) in
  assert (Set.size set_with_three = 3);
  assert (Set.to_list set_with_three = [ 1; 2; 3 ]);
  assert (Set.mem 2 set_with_three);
  assert (not (Set.mem 4 set_with_three));
  let duplicate_set = Set.add 2 set_with_three in
  assert (Set.size duplicate_set = 3);
  assert (Set.to_list duplicate_set = [ 1; 2; 3 ]);
  let removed_set = Set.remove 2 duplicate_set in
  assert (Set.size removed_set = 2);
  assert (not (Set.mem 2 removed_set));
  assert (Set.mem 2 duplicate_set);
  assert (Set.to_list (Set.remove 9 removed_set) = Set.to_list removed_set);
  let rec add_set_range n set =
    if n = 0 then set else add_set_range (n - 1) (Set.add n set)
  in
  let rec check_set_range n set =
    if n = 0 then ()
    else (
      assert (Set.mem n set);
      check_set_range (n - 1) set)
  in
  let hundred_set = add_set_range 100 empty_set in
  assert (Set.size hundred_set = 100);
  check_set_range 100 hundred_set;
  let left_set = Set.add 3 (Set.add 2 (Set.add 1 empty_set)) in
  let right_set = Set.add 4 (Set.add 3 (Set.add 2 empty_set)) in
  assert (Set.to_list (Set.union left_set right_set) = [ 1; 2; 3; 4 ]);
  assert (Set.to_list (Set.union empty_set left_set) = [ 1; 2; 3 ]);
  assert (Set.to_list (Set.inter left_set right_set) = [ 2; 3 ]);
  assert (Set.to_list (Set.inter empty_set left_set) = []);
  let account =
    {
      key = Bytes.of_string "account";
      lamports = 42;
      data = Bytes.of_string "payload";
      owner = Bytes.of_string "owner";
      is_signer = true;
      is_writable = false;
      executable = false;
    }
  in
  assert (account.lamports = 42);
  assert (account.is_signer);
  assert (not account.executable);
  let meta =
    { pubkey = account.key; is_writable = account.is_writable; is_signer = account.is_signer }
  in
  let instruction =
    { program_id = Bytes.of_string "program"; accounts = [| meta |]; data = account.data }
  in
  assert ((Array.get instruction.accounts 0).pubkey = account.key);
  assert (invoke instruction = 0);
  assert (invoke_signed instruction [| [| Bytes.of_string "seed" |] |] = 0);
  assert (
    create_program_address [| Bytes.of_string "seed" |] instruction.program_id
    = instruction.program_id);
  assert (
    try_find_program_address [| Bytes.of_string "seed" |] instruction.program_id
    = Some (instruction.program_id, 0));
  assert (Bytes.length Pubkey.zero = 32);
  assert (Bytes.for_all (( = ) '\000') Pubkey.zero);
  assert (Bytes.length Pubkey.token_program = 32);
  assert (Bytes.get Pubkey.token_program 0 = Char.chr 0x06);
  assert (Bytes.get Pubkey.token_program 31 = Char.chr 0xa9);
  assert (
    Pubkey.of_hex
      "4142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f60"
    = Bytes.of_string "ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`")
