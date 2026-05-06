(* record pattern target: let manhattan {x;y}=x+y *)
type point = {x : int; y : int}
let manhattan p =
let x = p.x in
let y = p.y in
x + y
