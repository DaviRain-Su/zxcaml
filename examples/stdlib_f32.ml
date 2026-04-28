let entrypoint _input =
  let xs = [ 1; 2; 3 ] in
  let ys = List.append (List.rev xs) [ 4; 5 ] in
  let list_score = List.length ys + List.hd ys + List.hd (List.tl ys) in
  let option_score =
    (if Option.is_some (Some 10) then 1 else 0)
    + (if Option.is_none None then 2 else 0)
    + Option.value (Some 6) 99 + Option.value None 7 + Option.get (Some 8)
  in
  let ok_result = Ok 11 in
  let error_result = Error 12 in
  let result_score =
    (if Result.is_ok ok_result then 3 else 0)
    + (if Result.is_error error_result then 4 else 0)
    + Option.get (Result.ok ok_result)
    + Option.get (Result.error error_result)
    + (if Option.is_none (Result.ok (Error 13)) then 5 else 0)
    + (if Option.is_none (Result.error (Ok 14)) then 6 else 0)
  in
  list_score + option_score + result_score
