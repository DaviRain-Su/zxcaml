(* Multi-file module demo (ADR-016): the bump instruction program.
   Second consumer of the shared multifile_counter_types.ml surface: same op
   ADT, different dispatch. Decodes a canned Bump 5 instruction, applies the
   clamp guard, and returns the surviving amount: 5. A stray Init decodes to
   2 and an out-of-range amount to 3. *)

open Multifile_counter_types

let entrypoint _input =
  match decode_op (Bytes.of_string "\001\005") with
  | Init -> 2
  | Bump amount -> if clamp_bump amount = amount then amount else 3
