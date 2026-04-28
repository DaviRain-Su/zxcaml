type color = Red | Green | Blue

let entrypoint _ =
  let red =
    match Red with
    | Red -> 1
    | Green -> 0
    | Blue -> 0
  in
  let green =
    match Green with
    | Red -> 0
    | Green -> 2
    | Blue -> 0
  in
  let blue =
    match Blue with
    | Red -> 0
    | Green -> 0
    | Blue -> 3
  in
  let total = red + green + blue in
  if total = 6 then 0 else 1
