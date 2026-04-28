let entrypoint _ =
  match Ok 5 with
  | Ok x -> x
  | Error _ -> 0
