let entrypoint (a : account) (data : bytes) =
  let _ = a in
  Bytes.length data > 0
