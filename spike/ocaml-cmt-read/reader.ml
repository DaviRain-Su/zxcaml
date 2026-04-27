(* Spike α — minimal Typedtree walker.
   Reads a .cmt file, prints every Texp_*/Tpat_* constructor with its
   resolved type and source location.

   Compiler-libs APIs used (all from `compiler-libs.common`):
     - Cmt_format.read_cmt          : load a .cmt
     - Cmt_format.cmt_annots         : get the `binary_annots` payload
     - Typedtree.{expression,pattern} field access
     - Tast_iterator.default_iterator : open recursion walker
     - Printtyp.type_expr            : pretty-print Types.type_expr
     - Location fields                : raw access to file:line:col
*)

(* ---- pretty-printing helpers ---- *)

let render_type (t : Types.type_expr) : string =
  Format.asprintf "%a" Printtyp.type_expr t

let render_loc (loc : Location.t) : string =
  let pos = loc.Location.loc_start in
  let file =
    if pos.Lexing.pos_fname = "" then "_unknown_" else pos.Lexing.pos_fname
  in
  let line = pos.Lexing.pos_lnum in
  let col = pos.Lexing.pos_cnum - pos.Lexing.pos_bol in
  Printf.sprintf "%s:%d:%d" file line col

let print_node ~kind ~ctor ~ty ~loc =
  Printf.printf "[%s] %-22s : %s @ %s\n" kind ctor ty loc

(* ---- constructor name extraction ---- *)

let texp_ctor_name (d : Typedtree.expression_desc) : string =
  match d with
  | Texp_ident _              -> "Texp_ident"
  | Texp_constant _           -> "Texp_constant"
  | Texp_let _                -> "Texp_let"
  | Texp_function _           -> "Texp_function"
  | Texp_apply _              -> "Texp_apply"
  | Texp_match _              -> "Texp_match"
  | Texp_try _                -> "Texp_try"
  | Texp_tuple _              -> "Texp_tuple"
  | Texp_construct _          -> "Texp_construct"
  | Texp_variant _            -> "Texp_variant"
  | Texp_record _             -> "Texp_record"
  | Texp_field _              -> "Texp_field"
  | Texp_setfield _           -> "Texp_setfield"
  | Texp_array _              -> "Texp_array"
  | Texp_ifthenelse _         -> "Texp_ifthenelse"
  | Texp_sequence _           -> "Texp_sequence"
  | Texp_while _              -> "Texp_while"
  | Texp_for _                -> "Texp_for"
  | Texp_send _               -> "Texp_send"
  | Texp_new _                -> "Texp_new"
  | Texp_instvar _            -> "Texp_instvar"
  | Texp_setinstvar _         -> "Texp_setinstvar"
  | Texp_override _           -> "Texp_override"
  | Texp_letmodule _          -> "Texp_letmodule"
  | Texp_letexception _       -> "Texp_letexception"
  | Texp_assert _             -> "Texp_assert"
  | Texp_lazy _               -> "Texp_lazy"
  | Texp_object _             -> "Texp_object"
  | Texp_pack _               -> "Texp_pack"
  | Texp_letop _              -> "Texp_letop"
  | Texp_unreachable          -> "Texp_unreachable"
  | Texp_extension_constructor _ -> "Texp_extension_constructor"
  | Texp_open _               -> "Texp_open"

(* Patterns are GADT-typed (value vs. computation). One name function
   handles both because we only need the constructor tag. *)
let tpat_ctor_name : type k. k Typedtree.pattern_desc -> string = function
  | Tpat_any                  -> "Tpat_any"
  | Tpat_var _                -> "Tpat_var"
  | Tpat_alias _              -> "Tpat_alias"
  | Tpat_constant _           -> "Tpat_constant"
  | Tpat_tuple _              -> "Tpat_tuple"
  | Tpat_construct _          -> "Tpat_construct"
  | Tpat_variant _            -> "Tpat_variant"
  | Tpat_record _             -> "Tpat_record"
  | Tpat_array _              -> "Tpat_array"
  | Tpat_lazy _               -> "Tpat_lazy"
  | Tpat_value _              -> "Tpat_value"
  | Tpat_exception _          -> "Tpat_exception"
  | Tpat_or _                 -> "Tpat_or"

(* ---- iterator hooks ---- *)

let walker : Tast_iterator.iterator =
  let base = Tast_iterator.default_iterator in
  { base with
    expr =
      (fun self e ->
        print_node
          ~kind:"EXPR"
          ~ctor:(texp_ctor_name e.exp_desc)
          ~ty:(render_type e.exp_type)
          ~loc:(render_loc e.exp_loc);
        base.expr self e);
    pat =
      (fun (type k) self (p : k Typedtree.general_pattern) ->
        print_node
          ~kind:"PAT "
          ~ctor:(tpat_ctor_name p.pat_desc)
          ~ty:(render_type p.pat_type)
          ~loc:(render_loc p.pat_loc);
        base.pat self p);
  }

(* ---- entry point ---- *)

let () =
  let cmt_file =
    if Array.length Sys.argv < 2 then begin
      prerr_endline "usage: reader <file.cmt>";
      exit 2
    end else Sys.argv.(1)
  in
  let info = Cmt_format.read_cmt cmt_file in
  Printf.printf "# cmt: %s  (modname=%s)\n"
    cmt_file (info.cmt_modname :> string);
  match info.cmt_annots with
  | Implementation str ->
      walker.structure walker str
  | Interface _ | Packed _ | Partial_implementation _ | Partial_interface _ ->
      prerr_endline "expected an Implementation .cmt"; exit 3
