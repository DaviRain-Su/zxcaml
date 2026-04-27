(* S-expression serializer for the ZxCaml OCaml frontend wire format.

   The serializer is intentionally hand-written to avoid any dependency beyond
   compiler-libs.common.  Version 0.4 contains top-level let declarations,
   one-argument lambdas, integer/string constants, identifiers, nested lets,
   whitelisted option/result constructor expressions, and basic match
   expressions. *)

open Format
open Zxc_subset

let version = "0.4"

let is_atom_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' | '\'' -> true
  | _ -> false

let pp_atom ppf atom =
  if atom <> "" && String.for_all is_atom_char atom then fprintf ppf "%s" atom
  else fprintf ppf "%S" atom

let pp_param ppf = function Anonymous -> fprintf ppf "_"

let rec pp_expr ppf = function
  | Const_int n -> fprintf ppf "(const-int %d)" n
  | Const_string value -> fprintf ppf "(const-string %S)" value
  | Var name -> fprintf ppf "(var %a)" pp_atom name
  | Lambda lambda ->
      fprintf ppf "(lambda (";
      pp_params ppf lambda.params;
      fprintf ppf ") %a)" pp_expr lambda.body
  | Let let_expr ->
      fprintf ppf "(let %a %a %a)" pp_atom let_expr.name pp_expr let_expr.value
        pp_expr let_expr.body
  | Ctor ctor ->
      fprintf ppf "(ctor %a" pp_atom ctor.name;
      List.iter (fun arg -> fprintf ppf " %a" pp_expr arg) ctor.args;
      fprintf ppf ")"
  | Match match_expr ->
      fprintf ppf "(match %a" pp_expr match_expr.scrutinee;
      List.iter (fun arm -> fprintf ppf " %a" pp_match_arm arm) match_expr.arms;
      fprintf ppf ")"

and pp_params ppf = function
  | [] -> ()
  | [ param ] -> pp_param ppf param
  | param :: rest ->
      fprintf ppf "%a" pp_param param;
      List.iter (fun param -> fprintf ppf " %a" pp_param param) rest

and pp_match_arm ppf arm =
  fprintf ppf "(case %a %a)" pp_match_pattern arm.pattern pp_expr arm.body

and pp_match_pattern ppf = function
  | Pat_any -> fprintf ppf "_"
  | Pat_var name -> fprintf ppf "(var %a)" pp_atom name
  | Pat_ctor ctor ->
      fprintf ppf "(ctor %a" pp_atom ctor.name;
      List.iter (fun arg -> fprintf ppf " %a" pp_match_pattern arg) ctor.args;
      fprintf ppf ")"

let pp_decl ppf decl =
  fprintf ppf "(let %a %a)" pp_atom decl.name pp_expr decl.body

let pp_module ppf = function
  | Module decls ->
      fprintf ppf "(zxcaml-cir %s (module" version;
      List.iter (fun decl -> fprintf ppf " %a" pp_decl decl) decls;
      fprintf ppf "))"

let to_string modul = asprintf "%a@." pp_module modul
