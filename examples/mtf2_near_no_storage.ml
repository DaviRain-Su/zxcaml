let entrypoint input =
  if Bytes.length input = 0 then 0
  else Char.code (Bytes.get input 0)
