type adjustment = Bonus of int | Penalty of int | Neutral

let entrypoint _input =
  let selected = Bonus 9 in
  let add_bonus =
    (* Capture an ADT value in a closure and inspect it with patterns later. *)
    let delta =
      match selected with Bonus n -> n | Penalty n -> 0 - n | Neutral -> 0
    in
    fun score ->
      match selected with
      | Bonus _ -> score + delta
      | Penalty _ -> score + delta
      | Neutral -> score
  in
  let penalty = Penalty 4 in
  let apply_penalty =
    let delta =
      match penalty with Bonus n -> n | Penalty n -> 0 - n | Neutral -> 0
    in
    fun score ->
      match penalty with
      | Bonus _ -> score + delta
      | Penalty _ -> score + delta
      | Neutral -> score
  in
  add_bonus 10 + apply_penalty 10
