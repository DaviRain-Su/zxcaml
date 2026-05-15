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

type rent = {
  lamports_per_byte_year : int;
  exemption_threshold : int;
  burn_percent : int;
}

type instructions_header = {
  instruction_count : int;
  offsets : int array;
}

type stake_history_entry = {
  epoch : int;
  effective : int;
  activating : int;
  deactivating : int;
}

type epoch_schedule = {
  slots_per_epoch : int;
  leader_schedule_slot_offset : int;
  warmup : bool;
  first_normal_epoch : int;
  first_normal_slot : int;
}

type account_data = bytes

type clock_record = clock

type rent_record = rent

type instruction_info = instruction

type stake_history_record = stake_history_entry

type epoch_schedule_record = epoch_schedule

module Option = struct
  let map f = function None -> None | Some x -> Some (f x)

  let bind x f = match x with None -> None | Some v -> f v

  let fold ~none ~some x = match x with None -> none | Some v -> some v

  let is_none x = match x with None -> true | Some _ -> false

  let is_some x = match x with None -> false | Some _ -> true

  let value x default = match x with None -> default | Some v -> v

  let rec unreachable () = unreachable ()

  let get x = match x with Some v -> v | None -> unreachable ()
end

module Result = struct
  let map f = function Ok x -> Ok (f x) | Error e -> Error e

  let map_error f = function Ok v -> Ok v | Error e -> Error (f e)

  let map_err f r = map_error f r

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

  let rec nth xs index =
    if index < 0 then unreachable ()
    else
      match xs with
      | [] -> unreachable ()
      | x :: rest -> if index = 0 then x else nth rest (index - 1)

  let rec exists predicate xs =
    match xs with [] -> false | x :: rest -> predicate x || exists predicate rest

  let rec for_all predicate xs =
    match xs with [] -> true | x :: rest -> predicate x && for_all predicate rest

  let rec find predicate xs =
    match xs with
    | [] -> unreachable ()
    | x :: rest -> if predicate x then x else find predicate rest

  let sort compare xs =
    let rec insert value sorted =
      match sorted with
      | [] -> [ value ]
      | x :: rest ->
          if compare value x <= 0 then value :: sorted else x :: insert value rest
    in
    let rec sort_rec unsorted =
      match unsorted with
      | [] -> []
      | x :: rest -> insert x (sort_rec rest)
    in
    sort_rec xs

  let rec combine left right =
    match (left, right) with
    | [], [] -> []
    | x :: xs, y :: ys -> (x, y) :: combine xs ys
    | _ -> unreachable ()

  let rec split pairs =
    match pairs with
    | [] -> ([], [])
    | (left, right) :: rest ->
        let lefts, rights = split rest in
        (left :: lefts, right :: rights)
end

module String = struct
  external length : string -> int = "%string_length"

  external get : string -> int -> char = "%string_safe_get"

  let sub value start len = Stdlib.String.sub value start len
end

module Char = struct
  external code : char -> int = "%identity"

  external chr : int -> char = "%identity"
end

module Fun = struct
  let id x = x

  let const x _ = x

  let flip f x y = f y x
end

let ( ^ ) left right = Stdlib.( ^ ) left right

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

  external blake3 : bytes -> bytes = "sol_blake3"

  external secp256k1_recover : bytes -> int -> bytes -> bytes
    = "sol_secp256k1_recover"
end

module Sysvar = struct
  external clock_from_account : account_data -> clock_record = "sysvar.readClock"

  external rent_from_account : account_data -> rent_record = "sysvar.readRent"

  external instructions_header_from_account : account_data -> instructions_header
    = "sysvar.readInstructionsHeader"

  external instruction_at : account_data -> int -> instruction_info
    = "sysvar.readInstructionAt"

  external stake_history_latest_from_account : account_data -> int -> stake_history_record array
    = "sysvar.readStakeHistory"

  external epoch_schedule_from_account : account_data -> epoch_schedule_record
    = "sysvar.readEpochSchedule"
end

module Bytes = struct
  include Stdlib.Bytes

  let iter f b =
    let len = length b in
    let rec loop i =
      if i >= len then ()
      else (let _ = f (get b i) in loop (i + 1))
    in
    loop 0

  let iteri f b =
    let len = length b in
    let rec loop i =
      if i >= len then ()
      else (let _ = f i (get b i) in loop (i + 1))
    in
    loop 0

  let fold_left f acc b =
    let len = length b in
    let rec loop i a = if i >= len then a else loop (i + 1) (f a (get b i)) in
    loop 0 acc

  let equal a b =
    let la = length a in
    let lb = length b in
    if la <> lb then false
    else
      let rec loop i =
        if i >= la then true
        else if get a i <> get b i then false
        else loop (i + 1)
      in
      loop 0

  let compare a b =
    let la = length a in
    let lb = length b in
    let rec loop i =
      if i >= la && i >= lb then 0
      else if i >= la then -1
      else if i >= lb then 1
      else
        let ca = get a i in
        let cb = get b i in
        if ca < cb then -1 else if ca > cb then 1 else loop (i + 1)
    in
    loop 0
end

module Fixed = struct
  (* Decimal fixed-point values with six fractional digits. The representation
     is intentionally just an int in the accepted OCaml subset: one unit equals
     one million scaled units. This keeps the first DeFi-oriented math surface
     portable across the interpreter, native Zig, and Solana BPF without adding
     a new runtime representation. *)
  type t = int

  let scale = 1000000

  let zero = 0

  let one = scale

  let of_scaled raw = raw

  let to_scaled value = value

  let of_int value = value * scale

  let to_int_trunc value = value / scale

  let to_int_floor value =
    let quotient = value / scale in
    let remainder = value mod scale in
    if value < 0 && remainder <> 0 then quotient - 1 else quotient

  let to_int_ceil value =
    let quotient = value / scale in
    let remainder = value mod scale in
    if value > 0 && remainder <> 0 then quotient + 1 else quotient

  let to_int_round value =
    if value >= 0 then (value + (scale / 2)) / scale
    else (value - (scale / 2)) / scale

  let add left right = left + right

  let sub left right = left - right

  let neg value = 0 - value

  let mul left right = (left * right) / scale

  let div left right = (left * scale) / right

  let mul_int value factor = value * factor

  let div_int value divisor = value / divisor

  let ratio numerator denominator = (numerator * scale) / denominator

  let bps basis_points = (basis_points * scale) / 10000

  let apply amount rate = (amount * rate) / scale

  let compare left right = if left < right then -1 else if left > right then 1 else 0

  let equal left right = left = right

  let min left right = if left <= right then left else right

  let max left right = if left >= right then left else right
end

module Amount = struct
  let fee_bps amount basis_points = (amount * basis_points) / 10000

  let discount_bps amount basis_points = amount - fee_bps amount basis_points

  let premium_bps amount basis_points = amount + fee_bps amount basis_points

  let apply_rate amount rate = Fixed.apply amount rate
end

module Format = struct
  (* Digit lookup string; using String.sub keeps each digit as a 1-character
     string and avoids relying on Char-to-string conversions that the
     Solana subset does not lower. *)
  let digits = "0123456789"

  let digit_char d = Stdlib.String.sub digits d 1

  let hex_digits = "0123456789abcdef"

  let hex_digit_char d = Stdlib.String.sub hex_digits d 1

  let rec int_to_string_pos x acc =
    if x = 0 then acc
    else
      let d = x - ((x / 10) * 10) in
      int_to_string_pos (x / 10) (digit_char d ^ acc)

  let int_to_string n =
    if n = 0 then "0"
    else if n < 0 then "-" ^ int_to_string_pos (0 - n) ""
    else int_to_string_pos n ""

  let rec hex_loop width n acc =
    if width <= 0 then acc
    else
      let d = n - ((n / 16) * 16) in
      hex_loop (width - 1) (n / 16) (hex_digit_char d ^ acc)

  (* hex_of_int width n: width = number of hex digits, n = non-negative int.
     The result is zero-padded to `width` digits using lowercase a-f. *)
  let hex_of_int width n = hex_loop width n ""
end

module Account = struct
  let key (account : account) = account.key

  let owner (account : account) = account.owner

  let data (account : account) = account.data

  let lamports (account : account) = account.lamports

  let data_len (account : account) = Bytes.length account.data

  let is_signer (account : account) = account.is_signer

  let is_writable (account : account) = account.is_writable

  let is_executable (account : account) = account.executable

  let has_key (account : account) key = Bytes.equal account.key key

  let is_owned_by (account : account) owner = Bytes.equal account.owner owner
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
