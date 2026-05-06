(* Property-test generators for ZxCaml.

   The PRNG is a deterministic 64-bit linear congruential generator (LCG)
   with the MMIX/PCG-style constants:

     seed' = seed * 6364136223846793005 + 1442695040888963407  (mod 2^64)

   OCaml Int64 arithmetic wraps modulo 2^64 for these operations, so a fixed
   int64 seed always produces the same sample stream.  The generator type is
   intentionally just a seed transformer: sample a generator by applying it to
   a seed and threading the returned seed into the next draw. *)

type seed = int64

type 'a generator = seed -> 'a * seed

type 'a shrinker = 'a -> 'a list

let filter_retry_budget = 64

let shrink_step_budget = 100

let lcg_multiplier = 6364136223846793005L

let lcg_increment = 1442695040888963407L

let next_seed seed = Int64.add (Int64.mul seed lcg_multiplier) lcg_increment

let next_bounded bound seed =
  if bound <= 0 then invalid_arg "Generators: bound must be positive";
  let seed' = next_seed seed in
  let bits = Int64.logand (Int64.shift_right_logical seed' 1) 0x3fffffffL in
  (Int64.to_int bits mod bound, seed')

let int_range ~low ~high : int generator =
 fun seed ->
  if high < low then invalid_arg "Generators.int_range: high must be >= low";
  let span = (high - low) + 1 in
  let offset, seed' = next_bounded span seed in
  (low + offset, seed')

let bool : bool generator =
 fun seed ->
  let bit, seed' = next_bounded 2 seed in
  (bit = 1, seed')

let string_of_len ~len : string generator =
 fun seed ->
  if len < 0 then invalid_arg "Generators.string_of_len: len must be >= 0";
  let bytes = Bytes.create len in
  let rec fill index current_seed =
    if index = len then current_seed
    else
      let offset, next = next_bounded 95 current_seed in
      Bytes.set bytes index (Char.chr (32 + offset));
      fill (index + 1) next
  in
  let seed' = fill 0 seed in
  (Bytes.to_string bytes, seed')

let list_of (element : 'a generator) max_len : 'a list generator =
 fun seed ->
  if max_len < 0 then invalid_arg "Generators.list_of: max length must be >= 0";
  let length, seed_after_length = next_bounded (max_len + 1) seed in
  let rec build remaining current_seed acc =
    if remaining = 0 then (List.rev acc, current_seed)
    else
      let value, next = element current_seed in
      build (remaining - 1) next (value :: acc)
  in
  build length seed_after_length []

let option_of (element : 'a generator) : 'a option generator =
 fun seed ->
  let choose_some, seed_after_choice = bool seed in
  if choose_some then
    let value, seed' = element seed_after_choice in
    (Some value, seed')
  else (None, seed_after_choice)

let tuple2 (left : 'a generator) (right : 'b generator) :
    ('a * 'b) generator =
 fun seed ->
  let left_value, seed_after_left = left seed in
  let right_value, seed_after_right = right seed_after_left in
  ((left_value, right_value), seed_after_right)

let map f (source : 'a generator) : 'b generator =
 fun seed ->
  let value, seed' = source seed in
  (f value, seed')

let filter predicate (source : 'a generator) : 'a generator =
 fun seed ->
  let rec retry remaining current_seed =
    if remaining = 0 then failwith "Generators.filter: retry budget exhausted"
    else
      let value, next = source current_seed in
      if predicate value then (value, next) else retry (remaining - 1) next
  in
  retry filter_retry_budget seed

let dedup_preserve_order values =
  let rec loop seen rest =
    match rest with
    | [] -> List.rev seen
    | value :: tail ->
        if List.exists (( = ) value) seen then loop seen tail
        else loop (value :: seen) tail
  in
  loop [] values

let shrink_int : int shrinker =
 fun value ->
  if value = 0 then []
  else
    let sign = if value < 0 then -1 else 1 in
    let magnitude = abs value in
    let rec binary_candidates delta acc =
      if delta = 0 then List.rev acc
      else
        let candidate = value - (sign * delta) in
        binary_candidates (delta / 2) (candidate :: acc)
    in
    dedup_preserve_order (0 :: binary_candidates (magnitude / 2) [])

let shrink_bool : bool shrinker = fun _ -> []

let string_drop_each value =
  let length = String.length value in
  let rec loop index acc =
    if index = length then List.rev acc
    else
      let candidate =
        String.sub value 0 index
        ^ String.sub value (index + 1) (length - index - 1)
      in
      loop (index + 1) (candidate :: acc)
  in
  loop 0 []

let string_halves value =
  let length = String.length value in
  if length <= 1 then []
  else
    let half = length / 2 in
    [ String.sub value 0 half; String.sub value half (length - half) ]

let shrink_string : string shrinker =
 fun value -> dedup_preserve_order (string_drop_each value @ string_halves value)

let rec take count values =
  if count <= 0 then []
  else match values with [] -> [] | x :: xs -> x :: take (count - 1) xs

let rec drop count values =
  if count <= 0 then values
  else match values with [] -> [] | _ :: xs -> drop (count - 1) xs

let rec rev_append left right =
  match left with [] -> right | x :: xs -> rev_append xs (x :: right)

let list_drop_each values =
  let rec loop prefix_rev rest acc =
    match rest with
    | [] -> List.rev acc
    | x :: tail ->
        let candidate = rev_append prefix_rev tail in
        loop (x :: prefix_rev) tail (candidate :: acc)
  in
  loop [] values []

let list_halves values =
  let length = List.length values in
  if length <= 1 then []
  else
    let half = length / 2 in
    [ take half values; drop half values ]

let shrink_list (_element_shrinker : 'a shrinker) : 'a list shrinker =
 fun values ->
  dedup_preserve_order (list_drop_each values @ list_halves values)

let shrink_option (element_shrinker : 'a shrinker) : 'a option shrinker =
 fun value ->
  match value with
  | None -> []
  | Some inner ->
      None :: List.map (fun shrunk -> Some shrunk) (element_shrinker inner)

let shrink_tuple2 (left_shrinker : 'a shrinker) (right_shrinker : 'b shrinker) :
    ('a * 'b) shrinker =
 fun (left, right) ->
  let left_candidates =
    List.map (fun shrunk_left -> (shrunk_left, right)) (left_shrinker left)
  in
  let right_candidates =
    List.map (fun shrunk_right -> (left, shrunk_right)) (right_shrinker right)
  in
  dedup_preserve_order (left_candidates @ right_candidates)

let shrink_map f (source_shrinker : 'a shrinker) value =
  List.map f (source_shrinker value)

let shrink_filter predicate (source_shrinker : 'a shrinker) value =
  List.filter predicate (source_shrinker value)

let shrink_to_minimal ?(budget = shrink_step_budget) ~fails
    (shrinker : 'a shrinker) initial =
  let rec first_failing candidates =
    match candidates with
    | [] -> None
    | candidate :: rest ->
        if fails candidate then Some candidate else first_failing rest
  in
  let rec loop current steps =
    match first_failing (shrinker current) with
    | None -> (current, steps)
    | Some candidate ->
        if steps >= budget then failwith "Generators.shrink: budget exhausted"
        else loop candidate (steps + 1)
  in
  if not (fails initial) then (initial, 0) else loop initial 0
