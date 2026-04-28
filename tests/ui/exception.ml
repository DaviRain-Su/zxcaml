let f x = try x with _ -> 0
let entrypoint _ = f 42
