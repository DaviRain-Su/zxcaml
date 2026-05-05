module rec M : sig
  val value : int -> int
end = struct
  let value x = x
end

let entrypoint _ = 0
