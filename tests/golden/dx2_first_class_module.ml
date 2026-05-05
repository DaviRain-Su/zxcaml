let entrypoint _ =
  let module M = struct let value = 1 end in
  M.value
