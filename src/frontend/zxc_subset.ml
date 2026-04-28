(* Typedtree subset checker for the ZxCaml frontend.

   This module consumes the fully typed OCaml Typedtree loaded from a .cmt
   file, accepts the current frontend subset, and reports the first
   unsupported Typedtree node as a JSON-friendly diagnostic. *)

open Asttypes
open Typedtree

type loc = {
  file : string;
  line : int;
  col : int;
  end_line : int;
  end_col : int;
}

type diagnostic = {
  severity : string;
  code : string;
  node_kind : string;
  loc : loc;
  message : string;
  hint : string option;
}

type param = Anonymous | Param of string

type expr =
  | Const_int of int
  | Const_string of string
  | Var of string
  | Lambda of lambda
  | App of app
  | Let of let_expr
  | If of if_expr
  | Prim of prim
  | Ctor of ctor
  | Match of match_expr

and lambda = {
  params : param list;
  body : expr;
}

and app = {
  callee : expr;
  args : expr list;
}

and let_expr = {
  name : string;
  value : expr;
  body : expr;
  is_rec : bool;
}

and if_expr = {
  cond : expr;
  then_branch : expr;
  else_branch : expr;
}

and prim = {
  op : string;
  args : expr list;
}

and ctor = {
  name : string;
  args : expr list;
}

and match_expr = {
  scrutinee : expr;
  arms : match_arm list;
}

and match_arm = {
  pattern : match_pattern;
  body : expr;
}

and match_pattern =
  | Pat_any
  | Pat_var of string
  | Pat_ctor of ctor_pattern

and ctor_pattern = {
  name : string;
  args : match_pattern list;
}

type decl = {
  name : string;
  body : expr;
  is_rec : bool;
}

type modul = Module of decl list

exception Unsupported of diagnostic

let loc_of_location (location : Location.t) =
  let start = location.loc_start in
  let finish = location.loc_end in
  let file =
    if start.Lexing.pos_fname = "" then "_unknown_" else start.Lexing.pos_fname
  in
  {
    file;
    line = start.Lexing.pos_lnum;
    col = start.Lexing.pos_cnum - start.Lexing.pos_bol;
    end_line = finish.Lexing.pos_lnum;
    end_col = finish.Lexing.pos_cnum - finish.Lexing.pos_bol;
  }

let unsupported ?message ?hint ~node_kind ~loc () =
  raise
    (Unsupported
       {
         severity = "error";
         code = "P1-UNSUPPORTED";
         node_kind;
         loc = loc_of_location loc;
         message =
           (match message with
           | Some message -> message
           | None ->
               Printf.sprintf
                 "%s is not supported in the current ZxCaml subset; expected \
                  top-level `let` declarations, integer constants, identifiers, \
                  string constants, one-argument functions, non-recursive nested \
                  `let` expressions, or the whitelisted constructors \
                  None/Some/Ok/Error/[]/::, including basic pattern matches over \
                  those values"
                 node_kind);
         hint;
       })

let unsupported_mutation ~feature ~node_kind ~loc =
  unsupported ~node_kind ~loc
    ~message:(Printf.sprintf "mutation (%s) is not supported in P1" feature)
    ~hint:"ZxCaml P1 is arena-only and does not support OCaml refs or mutable updates"
    ()

let structure_item_kind = function
  | Tstr_eval _ -> "Tstr_eval"
  | Tstr_value _ -> "Tstr_value"
  | Tstr_primitive _ -> "Tstr_primitive"
  | Tstr_type _ -> "Tstr_type"
  | Tstr_typext _ -> "Tstr_typext"
  | Tstr_exception _ -> "Tstr_exception"
  | Tstr_module _ -> "Tstr_module"
  | Tstr_recmodule _ -> "Tstr_recmodule"
  | Tstr_modtype _ -> "Tstr_modtype"
  | Tstr_open _ -> "Tstr_open"
  | Tstr_class _ -> "Tstr_class"
  | Tstr_class_type _ -> "Tstr_class_type"
  | Tstr_include _ -> "Tstr_include"
  | Tstr_attribute _ -> "Tstr_attribute"

let expr_kind = function
  | Texp_ident _ -> "Texp_ident"
  | Texp_constant _ -> "Texp_constant"
  | Texp_let _ -> "Texp_let"
  | Texp_function _ -> "Texp_function"
  | Texp_apply _ -> "Texp_apply"
  | Texp_match _ -> "Texp_match"
  | Texp_try _ -> "Texp_try"
  | Texp_tuple _ -> "Texp_tuple"
  | Texp_construct _ -> "Texp_construct"
  | Texp_variant _ -> "Texp_variant"
  | Texp_record _ -> "Texp_record"
  | Texp_field _ -> "Texp_field"
  | Texp_setfield _ -> "Texp_setfield"
  | Texp_array _ -> "Texp_array"
  | Texp_ifthenelse _ -> "Texp_ifthenelse"
  | Texp_sequence _ -> "Texp_sequence"
  | Texp_while _ -> "Texp_while"
  | Texp_for _ -> "Texp_for"
  | Texp_send _ -> "Texp_send"
  | Texp_new _ -> "Texp_new"
  | Texp_instvar _ -> "Texp_instvar"
  | Texp_setinstvar _ -> "Texp_setinstvar"
  | Texp_override _ -> "Texp_override"
  | Texp_letmodule _ -> "Texp_letmodule"
  | Texp_letexception _ -> "Texp_letexception"
  | Texp_assert _ -> "Texp_assert"
  | Texp_lazy _ -> "Texp_lazy"
  | Texp_object _ -> "Texp_object"
  | Texp_pack _ -> "Texp_pack"
  | Texp_letop _ -> "Texp_letop"
  | Texp_unreachable -> "Texp_unreachable"
  | Texp_extension_constructor _ -> "Texp_extension_constructor"
  | Texp_open _ -> "Texp_open"

let pat_kind : type k. k pattern_desc -> string = function
  | Tpat_any -> "Tpat_any"
  | Tpat_var _ -> "Tpat_var"
  | Tpat_alias _ -> "Tpat_alias"
  | Tpat_constant _ -> "Tpat_constant"
  | Tpat_tuple _ -> "Tpat_tuple"
  | Tpat_construct _ -> "Tpat_construct"
  | Tpat_variant _ -> "Tpat_variant"
  | Tpat_record _ -> "Tpat_record"
  | Tpat_array _ -> "Tpat_array"
  | Tpat_lazy _ -> "Tpat_lazy"
  | Tpat_value _ -> "Tpat_value"
  | Tpat_exception _ -> "Tpat_exception"
  | Tpat_or _ -> "Tpat_or"

let ident_name ident = Ident.name ident

let longident_name (lid : Longident.t Location.loc) = Longident.last lid.txt

let is_whitelisted_constructor = function
  | "None" | "Some" | "Ok" | "Error" | "[]" | "::" -> true
  | _ -> false

let is_whitelisted_prim = function
  | "+" | "-" | "*" | "/" | "mod" | "=" | "<>" | "<" | "<=" | ">" | ">=" -> true
  | _ -> false

let is_mutation_primitive = function
  | "ref" | ":=" | "!" -> true
  | _ -> false

let parse_binding_name (pat : pattern) =
  match pat.pat_desc with
  | Tpat_any -> "_"
  | Tpat_var (ident, _, _) -> ident_name ident
  | other -> unsupported ~node_kind:(pat_kind other) ~loc:pat.pat_loc ()

let parse_param (param : function_param) =
  match (param.fp_arg_label, param.fp_kind) with
  | Nolabel, Tparam_pat pat -> (
      match pat.pat_desc with
      | Tpat_any -> Anonymous
      | Tpat_var (ident, _, _) -> Param (ident_name ident)
      | other -> unsupported ~node_kind:(pat_kind other) ~loc:pat.pat_loc ())
  | _, Tparam_pat pat ->
      unsupported ~node_kind:"labelled-parameter" ~loc:pat.pat_loc ()
  | _, Tparam_optional_default (pat, _) ->
      unsupported ~node_kind:"optional-parameter" ~loc:pat.pat_loc ()

let rec parse_match_scrutinee (expr : expression) =
  match expr.exp_desc with
  | Texp_constant (Const_int n) -> Const_int n
  | Texp_ident (_, lid, _) -> Var (longident_name lid)
  | Texp_construct (_lid, constructor, args) ->
      let name = constructor.Types.cstr_name in
      if is_whitelisted_constructor name then
        Ctor { name; args = List.map parse_match_scrutinee args }
      else unsupported ~node_kind:("Texp_construct(" ^ name ^ ")") ~loc:expr.exp_loc ()
  | other -> unsupported ~node_kind:(expr_kind other) ~loc:expr.exp_loc ()

let parse_simple_pattern (pat : pattern) =
  match pat.pat_desc with
  | Tpat_any -> Pat_any
  | Tpat_var (ident, _, _) -> Pat_var (ident_name ident)
  | other -> unsupported ~node_kind:(pat_kind other) ~loc:pat.pat_loc ()

let rec parse_match_pattern (pat : pattern) =
  match pat.pat_desc with
  | Tpat_any -> Pat_any
  | Tpat_var (ident, _, _) -> Pat_var (ident_name ident)
  | Tpat_construct (_lid, constructor, args, _) ->
      let name = constructor.Types.cstr_name in
      if is_whitelisted_constructor name then
        Pat_ctor { name; args = List.map parse_simple_pattern args }
      else unsupported ~node_kind:("Tpat_construct(" ^ name ^ ")") ~loc:pat.pat_loc ()
  | other -> unsupported ~node_kind:(pat_kind other) ~loc:pat.pat_loc ()

let parse_computation_pattern (pat : computation general_pattern) =
  match pat.pat_desc with
  | Tpat_value value_pat -> parse_match_pattern (value_pat :> pattern)
  | other -> unsupported ~node_kind:(pat_kind other) ~loc:pat.pat_loc ()

let rec parse_match_case (case : computation case) =
  (match case.c_guard with
  | None -> ()
  | Some guard ->
      unsupported ~node_kind:"Texp_match(guard)" ~loc:guard.exp_loc ());
  let pattern = parse_computation_pattern case.c_lhs in
  let body = parse_expr case.c_rhs in
  { pattern; body }

and parse_apply_args args =
  let parse_one = function
    | Nolabel, Some arg -> parse_expr arg
    | _, Some arg -> unsupported ~node_kind:"labelled-application" ~loc:arg.exp_loc ()
    | _, None -> unsupported ~node_kind:"partial-application" ~loc:Location.none ()
  in
  List.map parse_one args

and parse_expr (expr : expression) =
  match expr.exp_desc with
  | Texp_constant (Const_int n) -> Const_int n
  | Texp_constant (Const_string (value, _, _)) -> Const_string value
  | Texp_ident (_, lid, _) -> Var (longident_name lid)
  | Texp_function ([ param ], Tfunction_body body) ->
      let param = parse_param param in
      let body = parse_expr body in
      Lambda { params = [ param ]; body }
  | Texp_function (_params, Tfunction_body _) ->
      unsupported ~node_kind:"Texp_function" ~loc:expr.exp_loc ()
  | Texp_function (_params, Tfunction_cases _) ->
      unsupported ~node_kind:"Tfunction_cases" ~loc:expr.exp_loc ()
  | Texp_let (Nonrecursive, [ binding ], body) ->
      let name = parse_binding_name binding.vb_pat in
      let value = parse_expr binding.vb_expr in
      let body = parse_expr body in
      Let { name; value; body; is_rec = false }
  | Texp_let (Recursive, [ binding ], body) ->
      let name = parse_binding_name binding.vb_pat in
      let value = parse_expr binding.vb_expr in
      let body = parse_expr body in
      Let { name; value; body; is_rec = true }
  | Texp_let (_, [], _) ->
      unsupported ~node_kind:"Texp_let(empty)" ~loc:expr.exp_loc ()
  | Texp_let (_, _ :: _ :: _, _) ->
      unsupported ~node_kind:"Texp_let(and)" ~loc:expr.exp_loc ()
  | Texp_constant _ -> unsupported ~node_kind:"Texp_constant" ~loc:expr.exp_loc ()
  | Texp_construct (_lid, constructor, args) ->
      let name = constructor.Types.cstr_name in
      if is_whitelisted_constructor name then
        Ctor { name; args = List.map parse_expr args }
      else unsupported ~node_kind:("Texp_construct(" ^ name ^ ")") ~loc:expr.exp_loc ()
  | Texp_apply ({ exp_desc = Texp_ident (_, lid, _) }, args)
    when is_whitelisted_prim (longident_name lid) ->
      Prim { op = longident_name lid; args = parse_apply_args args }
  | Texp_apply ({ exp_desc = Texp_ident (_, lid, _) }, _args)
    when is_mutation_primitive (longident_name lid) ->
      unsupported_mutation ~feature:(longident_name lid) ~node_kind:"Texp_apply"
        ~loc:expr.exp_loc
  | Texp_apply (callee, args) -> App { callee = parse_expr callee; args = parse_apply_args args }
  | Texp_ifthenelse (cond, then_branch, Some else_branch) ->
      If
        {
          cond = parse_expr cond;
          then_branch = parse_expr then_branch;
          else_branch = parse_expr else_branch;
        }
  | Texp_ifthenelse (_, _, None) ->
      unsupported ~node_kind:"Texp_ifthenelse(no-else)" ~loc:expr.exp_loc ()
  | Texp_match (scrutinee, cases, _) ->
      let scrutinee = parse_match_scrutinee scrutinee in
      let arms = List.map parse_match_case cases in
      Match { scrutinee; arms }
  | other -> unsupported ~node_kind:(expr_kind other) ~loc:expr.exp_loc ()

let parse_value_binding (binding : value_binding) =
  let name = parse_binding_name binding.vb_pat in
  let body = parse_expr binding.vb_expr in
  { name; body; is_rec = false }

let parse_structure_item (item : structure_item) =
  match item.str_desc with
  | Tstr_value (Nonrecursive, [ binding ]) -> [ parse_value_binding binding ]
  | Tstr_value (Recursive, [ binding ]) ->
      let decl = parse_value_binding binding in
      [ { decl with is_rec = true } ]
  | Tstr_value (_, []) ->
      unsupported ~node_kind:"Tstr_value(empty)" ~loc:item.str_loc ()
  | Tstr_value (_, _ :: _ :: _) ->
      unsupported ~node_kind:"Tstr_value(and)" ~loc:item.str_loc ()
  | other ->
      unsupported ~node_kind:(structure_item_kind other) ~loc:item.str_loc ()

let of_structure (structure : structure) =
  Module (List.concat_map parse_structure_item structure.str_items)
