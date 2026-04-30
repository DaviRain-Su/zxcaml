let classify_int x =
  match x with
  | 0 | 1 | 2 -> 10
  | n -> n

let classify_char c =
  match c with
  | 'a' -> 4
  | _ -> 0

let entrypoint _input =
  let int_score = classify_int 1 in
  let string_score =
    match "hello" with
    | "hello" -> 1
    | _ -> 0
  in
  let alias_score =
    match (3, 4) with
    | (a, _) as whole -> (match whole with (_, b) -> a + b)
  in
  let _result = int_score + string_score + alias_score in
  if _result = 18 then 0 else 1
