open Multifile_ok_util

let entrypoint _input =
  let a = area (Circle 2) in
  let b = area (Square 4) in
  let c = scale 5 in
  let d = Multifile_ok_util.scale 2 in
  a + b + c + d
