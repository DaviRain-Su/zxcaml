(* Shared instruction surface for the multi-file counter trio (ADR-016).
   This file has no entrypoint: multifile_counter_init.ml and
   multifile_counter_bump.ml both `open Multifile_counter_types`, and the
   frontend resolves that open to this file and joins the closure into one
   flat program. *)

type op = Init | Bump of int

(* Bounds-checked byte read; out-of-range offsets decode as 0 so an empty
   instruction falls back to Init, matching the sBPF runtime helpers. *)
let read_u8 data offset =
  if offset < Bytes.length data then Char.code (Bytes.get data offset) else 0

(* Instruction byte 0 selects the operation: 0 = Init, anything else is Bump
   with the amount in instruction byte 1. *)
let decode_op data =
  let tag = read_u8 data 0 in
  if tag = 0 then Init else Bump (read_u8 data 1)

let clamp_bump amount =
  if amount < 0 then 0
  else if amount > 99 then 99
  else amount

let op_code op =
  match op with
  | Init -> 0
  | Bump _ -> 1
