external storage_write : bytes -> unit = "near.storage_write"

let entrypoint input =
  storage_write input;
  0
