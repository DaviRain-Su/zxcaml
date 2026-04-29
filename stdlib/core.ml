(* Core standard-library subset for ZxCaml.

   This module contains the small OCaml definitions that the P1 frontend and
   downstream pipeline agree to support.  It is intentionally valid upstream
   OCaml so ocamlc can type-check it as an oracle while ZxCaml grows its own
   runtime representation. *)

type 'a option = None | Some of 'a

type ('a, 'b) result = Ok of 'a | Error of 'b

type account = {
  key : bytes;
  lamports : int;
  data : bytes;
  owner : bytes;
  is_signer : bool;
  is_writable : bool;
  executable : bool;
}

type account_meta = {
  pubkey : bytes;
  is_writable : bool;
  is_signer : bool;
}

type instruction = {
  program_id : bytes;
  accounts : account_meta array;
  data : bytes;
}

type pubkey = bytes

type signer_seeds = bytes array

type error = {
  program_id_index : int;
  code : int;
}

type clock = {
  slot : int;
  epoch_start_timestamp : int;
  epoch : int;
  leader_schedule_epoch : int;
  unix_timestamp : int;
}

module Option = struct
  let map f = function None -> None | Some x -> Some (f x)

  let bind x f = match x with None -> None | Some v -> f v

  let is_none x = match x with None -> true | Some _ -> false

  let is_some x = match x with None -> false | Some _ -> true

  let value x default = match x with None -> default | Some v -> v

  let rec unreachable () = unreachable ()

  let get x = match x with Some v -> v | None -> unreachable ()
end

module Result = struct
  let map f = function Ok x -> Ok (f x) | Error e -> Error e

  let bind x f = match x with Ok v -> f v | Error e -> Error e

  let is_ok x = match x with Ok _ -> true | Error _ -> false

  let is_error x = match x with Ok _ -> false | Error _ -> true

  let ok x = match x with Ok v -> Some v | Error _ -> None

  let error x = match x with Ok _ -> None | Error e -> Some e
end

module List = struct
  let rec length xs = match xs with [] -> 0 | _ :: rest -> 1 + length rest

  let rec map f xs =
    match xs with [] -> [] | x :: rest -> f x :: map f rest

  let rec filter predicate xs =
    match xs with
    | [] -> []
    | x :: rest ->
        if predicate x then x :: filter predicate rest else filter predicate rest

  let rec fold_left f acc xs =
    match xs with [] -> acc | x :: rest -> fold_left f (f acc x) rest

  let rev xs = fold_left (fun acc x -> x :: acc) [] xs

  let rec append left right =
    match left with [] -> right | x :: rest -> x :: append rest right

  let rec unreachable () = unreachable ()

  let hd xs = match xs with [] -> unreachable () | x :: _ -> x

  let tl xs = match xs with [] -> unreachable () | _ :: rest -> rest
end

module Map = struct
  type ('k, 'v) tree =
    | Empty
    | Node of ('k, 'v) tree * 'k * 'v * ('k, 'v) tree * int

  type ('k, 'v) t = { compare : 'k -> 'k -> int; tree : ('k, 'v) tree }

  let tree_size tree = match tree with Empty -> 0 | Node (_, _, _, _, size) -> size

  let create left key value right =
    Node (left, key, value, right, tree_size left + tree_size right + 1)

  let singleton_tree key value = create Empty key value Empty

  let delta = 3

  let ratio = 2

  let balance left key value right =
    let left_size = tree_size left in
    let right_size = tree_size right in
    if left_size + right_size <= 1 then create left key value right
    else if left_size > delta * right_size then
      match left with
      | Empty -> create left key value right
      | Node (left_left, left_key, left_value, left_right, _) ->
          if tree_size left_left >= ratio * tree_size left_right then
            create left_left left_key left_value (create left_right key value right)
          else (
            match left_right with
            | Empty ->
                create left_left left_key left_value
                  (create left_right key value right)
            | Node
                ( left_right_left,
                  left_right_key,
                  left_right_value,
                  left_right_right,
                  _ ) ->
                create
                  (create left_left left_key left_value left_right_left)
                  left_right_key left_right_value
                  (create left_right_right key value right))
    else if right_size > delta * left_size then
      match right with
      | Empty -> create left key value right
      | Node (right_left, right_key, right_value, right_right, _) ->
          if tree_size right_right >= ratio * tree_size right_left then
            create (create left key value right_left) right_key right_value
              right_right
          else (
            match right_left with
            | Empty ->
                create (create left key value right_left) right_key right_value
                  right_right
            | Node
                ( right_left_left,
                  right_left_key,
                  right_left_value,
                  right_left_right,
                  _ ) ->
                create
                  (create left key value right_left_left)
                  right_left_key right_left_value
                  (create right_left_right right_key right_value right_right))
    else create left key value right

  let empty compare = { compare; tree = Empty }

  let singleton key value compare = { compare; tree = singleton_tree key value }

  let rec add_tree compare key value tree =
    match tree with
    | Empty -> singleton_tree key value
    | Node (left, node_key, node_value, right, _) ->
        let ordering = compare key node_key in
        if ordering = 0 then create left key value right
        else if ordering < 0 then
          balance (add_tree compare key value left) node_key node_value right
        else balance left node_key node_value (add_tree compare key value right)

  let add key value map =
    { map with tree = add_tree map.compare key value map.tree }

  let rec find_tree compare key tree =
    match tree with
    | Empty -> None
    | Node (left, node_key, node_value, right, _) ->
        let ordering = compare key node_key in
        if ordering = 0 then Some node_value
        else if ordering < 0 then find_tree compare key left
        else find_tree compare key right

  let find key map = find_tree map.compare key map.tree

  let mem key map =
    match find key map with None -> false | Some _ -> true

  let rec min_binding tree =
    match tree with
    | Empty -> None
    | Node (Empty, key, value, _, _) -> Some (key, value)
    | Node (left, _, _, _, _) -> min_binding left

  let rec remove_min_binding tree =
    match tree with
    | Empty -> Empty
    | Node (Empty, _, _, right, _) -> right
    | Node (left, key, value, right, _) ->
        balance (remove_min_binding left) key value right

  let merge left right =
    match (left, right) with
    | Empty, tree -> tree
    | tree, Empty -> tree
    | _ -> (
        match min_binding right with
        | None -> left
        | Some (key, value) -> balance left key value (remove_min_binding right))

  let rec remove_tree compare key tree =
    match tree with
    | Empty -> Empty
    | Node (left, node_key, node_value, right, _) ->
        let ordering = compare key node_key in
        if ordering = 0 then merge left right
        else if ordering < 0 then
          balance (remove_tree compare key left) node_key node_value right
        else balance left node_key node_value (remove_tree compare key right)

  let remove key map =
    { map with tree = remove_tree map.compare key map.tree }

  let size map = tree_size map.tree

  let rec to_list_acc tree acc =
    match tree with
    | Empty -> acc
    | Node (left, key, value, right, _) ->
        to_list_acc left ((key, value) :: to_list_acc right acc)

  let to_list map = to_list_acc map.tree []
end

module Set = struct
  type 'a tree = Empty | Node of 'a tree * 'a * 'a tree * int

  type 'a t = { compare : 'a -> 'a -> int; tree : 'a tree }

  let tree_size tree = match tree with Empty -> 0 | Node (_, _, _, size) -> size

  let create left value right =
    Node (left, value, right, tree_size left + tree_size right + 1)

  let singleton_tree value = create Empty value Empty

  let delta = 3

  let ratio = 2

  let balance left value right =
    let left_size = tree_size left in
    let right_size = tree_size right in
    if left_size + right_size <= 1 then create left value right
    else if left_size > delta * right_size then
      match left with
      | Empty -> create left value right
      | Node (left_left, left_value, left_right, _) ->
          if tree_size left_left >= ratio * tree_size left_right then
            create left_left left_value (create left_right value right)
          else (
            match left_right with
            | Empty -> create left_left left_value (create left_right value right)
            | Node (left_right_left, left_right_value, left_right_right, _) ->
                create
                  (create left_left left_value left_right_left)
                  left_right_value
                  (create left_right_right value right))
    else if right_size > delta * left_size then
      match right with
      | Empty -> create left value right
      | Node (right_left, right_value, right_right, _) ->
          if tree_size right_right >= ratio * tree_size right_left then
            create (create left value right_left) right_value right_right
          else (
            match right_left with
            | Empty -> create (create left value right_left) right_value right_right
            | Node (right_left_left, right_left_value, right_left_right, _) ->
                create
                  (create left value right_left_left)
                  right_left_value
                  (create right_left_right right_value right_right))
    else create left value right

  let empty compare = { compare; tree = Empty }

  let singleton value compare = { compare; tree = singleton_tree value }

  let rec add_tree compare value tree =
    match tree with
    | Empty -> singleton_tree value
    | Node (left, node_value, right, _) ->
        let ordering = compare value node_value in
        if ordering = 0 then create left value right
        else if ordering < 0 then balance (add_tree compare value left) node_value right
        else balance left node_value (add_tree compare value right)

  let add value set = { set with tree = add_tree set.compare value set.tree }

  let rec mem_tree compare value tree =
    match tree with
    | Empty -> false
    | Node (left, node_value, right, _) ->
        let ordering = compare value node_value in
        if ordering = 0 then true
        else if ordering < 0 then mem_tree compare value left
        else mem_tree compare value right

  let mem value set = mem_tree set.compare value set.tree

  let rec min_elt tree =
    match tree with
    | Empty -> None
    | Node (Empty, value, _, _) -> Some value
    | Node (left, _, _, _) -> min_elt left

  let rec remove_min_elt tree =
    match tree with
    | Empty -> Empty
    | Node (Empty, _, right, _) -> right
    | Node (left, value, right, _) -> balance (remove_min_elt left) value right

  let merge left right =
    match (left, right) with
    | Empty, tree -> tree
    | tree, Empty -> tree
    | _ -> (
        match min_elt right with
        | None -> left
        | Some value -> balance left value (remove_min_elt right))

  let rec remove_tree compare value tree =
    match tree with
    | Empty -> Empty
    | Node (left, node_value, right, _) ->
        let ordering = compare value node_value in
        if ordering = 0 then merge left right
        else if ordering < 0 then balance (remove_tree compare value left) node_value right
        else balance left node_value (remove_tree compare value right)

  let remove value set =
    { set with tree = remove_tree set.compare value set.tree }

  let size set = tree_size set.tree

  let rec to_list_acc tree acc =
    match tree with
    | Empty -> acc
    | Node (left, value, right, _) ->
        to_list_acc left (value :: to_list_acc right acc)

  let to_list set = to_list_acc set.tree []

  let union left right =
    List.fold_left (fun acc value -> add value acc) left (to_list right)

  let inter left right =
    List.fold_left
      (fun acc value -> if mem value right then add value acc else acc)
      (empty left.compare) (to_list left)
end

module Syscall = struct
  external sol_log : string -> unit = "sol_log_"

  external sol_log_64 : int -> int -> int -> int -> int -> unit = "sol_log_64_"

  external sol_sha256 : 'a -> 'a = "sol_sha256"

  external sol_get_clock_sysvar : unit -> clock = "sol_get_clock_sysvar"

  external sol_remaining_compute_units : unit -> int
    = "sol_remaining_compute_units"
end

module Crypto = struct
  external sha256 : bytes -> bytes = "sol_sha256"

  external keccak256 : bytes -> bytes = "sol_keccak256"
end

module Pubkey = struct
  let zero : pubkey = Bytes.make 32 '\000'

  let token_program : pubkey =
    Bytes.of_string
      "\006\221\246\225\215\101\161\147\217\203\225\070\206\235\121\172\028\180\133\237\095\091\055\145\058\140\245\133\126\255\000\169"

  let of_hex hex : pubkey =
    let hex_nibble c =
      match c with
      | '0' .. '9' -> Char.code c - Char.code '0'
      | 'a' .. 'f' -> 10 + Char.code c - Char.code 'a'
      | 'A' .. 'F' -> 10 + Char.code c - Char.code 'A'
      | _ -> invalid_arg "Pubkey.of_hex: non-hex character"
    in
    if String.length hex <> 64 then
      invalid_arg "Pubkey.of_hex: expected exactly 64 hex characters";
    let out = Bytes.create 32 in
    for index = 0 to 31 do
      let high = hex_nibble (String.get hex (index * 2)) in
      let low = hex_nibble (String.get hex ((index * 2) + 1)) in
      Bytes.set out index (Char.chr ((high * 16) + low))
    done;
    out
end

module Error = struct
  let make program_id_index code = { program_id_index; code }

  let encode err = (err.program_id_index * 256) + err.code

  let encode_code program_id_index code = (program_id_index * 256) + code
end

let invoke (_instruction : instruction) = 0

let invoke_signed (_instruction : instruction) (_signer_seeds : signer_seeds array)
    =
  0

let create_program_address (_seeds : signer_seeds) (program_id : bytes) =
  program_id

let try_find_program_address (_seeds : signer_seeds) (program_id : bytes) =
  Some (program_id, 0)

let head xs = match xs with [] -> None | x :: _ -> Some x

let tail xs = match xs with [] -> None | _ :: rest -> Some rest
