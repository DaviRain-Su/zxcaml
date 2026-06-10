(* Multi-file module demo (ADR-016): the init instruction program.
   The op ADT and instruction decoding live in multifile_counter_types.ml,
   shared with multifile_counter_bump.ml. Decodes a canned Init instruction
   and returns its wire code: 0. *)

open Multifile_counter_types

let entrypoint _input = op_code (decode_op (Bytes.of_string "\000"))
