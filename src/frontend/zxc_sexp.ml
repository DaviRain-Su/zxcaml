(* S-expression serializer for the ZxCaml OCaml frontend wire format.

   The serializer is intentionally hand-written to avoid any dependency beyond
   compiler-libs.common.  M0 emits version 0.1 and contains only top-level
   one-argument functions returning integer constants. *)

open Format
open Zxc_subset

let version = "0.1"

let is_atom_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' | '\'' -> true
  | _ -> false

let pp_atom ppf atom =
  if atom <> "" && String.for_all is_atom_char atom then fprintf ppf "%s" atom
  else fprintf ppf "%S" atom

let pp_expr ppf = function Const_int n -> fprintf ppf "(const-int %d)" n

let pp_param ppf = function Anonymous -> fprintf ppf "_"

let pp_decl ppf decl =
  fprintf ppf "(let %a (lambda (%a) %a))" pp_atom decl.name pp_param decl.param
    pp_expr decl.body

let pp_module ppf = function
  | Module decls ->
      fprintf ppf "(zxcaml-cir %s (module" version;
      List.iter (fun decl -> fprintf ppf " %a" pp_decl decl) decls;
      fprintf ppf "))"

let to_string modul = asprintf "%a@." pp_module modul
