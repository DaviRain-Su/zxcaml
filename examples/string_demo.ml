(* Demonstrates String and Char operations through ANF and Zig codegen. *)

let entrypoint _input =
  let hello = "hello" in
  let combined = hello ^ " world" in
  let middle = String.sub combined 1 3 in
  let expected_e = Char.chr 101 in
  let expected_l = Char.chr 108 in
  let code_a = Char.code (Char.chr 97) in
  if String.length combined = 11 then
    if String.get combined 1 = expected_e then
      if String.length middle = 3 then
        if String.get middle 0 = expected_e then
          if String.get middle 2 = expected_l then
            if code_a = 97 then 0 else 6
          else 5
        else 4
      else 3
    else 2
  else 1
