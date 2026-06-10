type shape =
  | Circle of int
  | Square of int

let scale x = x * 3

let area s =
  match s with
  | Circle r -> r * r * 3
  | Square w -> w * w
