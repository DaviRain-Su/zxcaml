(* S-expression serializer for the ZxCaml OCaml frontend wire format.

   The serializer is intentionally hand-written to avoid any dependency beyond
   compiler-libs.common.  Version 0.2 contains top-level let declarations,
   one-argument lambdas, integer constants, identifiers, and nested lets. *)

open Format
open Zxc_subset

let version = "0.2"

let is_atom_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' | '\'' -> true
  | _ -> false

let pp_atom ppf atom =
  if atom <> "" && String.for_all is_atom_char atom then fprintf ppf "%s" atom
  else fprintf ppf "%S" atom

let pp_param ppf = function Anonymous -> fprintf ppf "_"

let rec pp_expr ppf = function
  | Const_int n -> fprintf ppf "(const-int %d)" n
  | Var name -> fprintf ppf "(var %a)" pp_atom name
  | Lambda lambda ->
      fprintf ppf "(lambda (";
      pp_params ppf lambda.params;
      fprintf ppf ") %a)" pp_expr lambda.body
  | Let let_expr ->
      fprintf ppf "(let %a %a %a)" pp_atom let_expr.name pp_expr let_expr.value
        pp_expr let_expr.body

and pp_params ppf = function
  | [] -> ()
  | [ param ] -> pp_param ppf param
  | param :: rest ->
      fprintf ppf "%a" pp_param param;
      List.iter (fun param -> fprintf ppf " %a" pp_param param) rest

let pp_decl ppf decl =
  fprintf ppf "(let %a %a)" pp_atom decl.name pp_expr decl.body

let pp_module ppf = function
  | Module decls ->
      fprintf ppf "(zxcaml-cir %s (module" version;
      List.iter (fun decl -> fprintf ppf " %a" pp_decl decl) decls;
      fprintf ppf "))"

let to_string modul = asprintf "%a@." pp_module modul
