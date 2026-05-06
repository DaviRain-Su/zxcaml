let nested =
  if true then
let a = 1 in
let b = (let c = 2 in c + 3)in
(a + b) * (a + (b + 4))
else 0
