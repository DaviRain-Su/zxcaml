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
}

type param = Anonymous

type expr =
  | Const_int of int
  | Var of string
  | Lambda of lambda
  | Let of let_expr

and lambda = {
  params : param list;
  body : expr;
}

and let_expr = {
  name : string;
  value : expr;
  body : expr;
}

type decl = {
  name : string;
  body : expr;
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

let unsupported ~node_kind ~loc =
  raise
    (Unsupported
       {
         severity = "error";
         code = "M0-UNSUPPORTED";
         node_kind;
         loc = loc_of_location loc;
         message =
           Printf.sprintf
             "%s is not supported in the current ZxCaml subset; expected \
              top-level `let` declarations, integer constants, identifiers, \
              one-argument functions, or non-recursive nested `let` \
              expressions"
             node_kind;
       })

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

let parse_binding_name (pat : pattern) =
  match pat.pat_desc with
  | Tpat_var (ident, _, _) -> ident_name ident
  | other -> unsupported ~node_kind:(pat_kind other) ~loc:pat.pat_loc

let parse_param (param : function_param) =
  match (param.fp_arg_label, param.fp_kind) with
  | Nolabel, Tparam_pat pat -> (
      match pat.pat_desc with
      | Tpat_any | Tpat_var _ -> Anonymous
      | other -> unsupported ~node_kind:(pat_kind other) ~loc:pat.pat_loc)
  | _, Tparam_pat pat ->
      unsupported ~node_kind:"labelled-parameter" ~loc:pat.pat_loc
  | _, Tparam_optional_default (pat, _) ->
      unsupported ~node_kind:"optional-parameter" ~loc:pat.pat_loc

let rec parse_expr (expr : expression) =
  match expr.exp_desc with
  | Texp_constant (Const_int n) -> Const_int n
  | Texp_ident (_, lid, _) -> Var (longident_name lid)
  | Texp_function ([ param ], Tfunction_body body) ->
      let param = parse_param param in
      let body = parse_expr body in
      Lambda { params = [ param ]; body }
  | Texp_function (_params, Tfunction_body _) ->
      unsupported ~node_kind:"Texp_function" ~loc:expr.exp_loc
  | Texp_function (_params, Tfunction_cases _) ->
      unsupported ~node_kind:"Tfunction_cases" ~loc:expr.exp_loc
  | Texp_let (Nonrecursive, [ binding ], body) ->
      let name = parse_binding_name binding.vb_pat in
      let value = parse_expr binding.vb_expr in
      let body = parse_expr body in
      Let { name; value; body }
  | Texp_let (Recursive, _, _) ->
      unsupported ~node_kind:"Texp_let(recursive)" ~loc:expr.exp_loc
  | Texp_let (_, [], _) ->
      unsupported ~node_kind:"Texp_let(empty)" ~loc:expr.exp_loc
  | Texp_let (_, _ :: _ :: _, _) ->
      unsupported ~node_kind:"Texp_let(and)" ~loc:expr.exp_loc
  | Texp_constant _ -> unsupported ~node_kind:"Texp_constant" ~loc:expr.exp_loc
  | other -> unsupported ~node_kind:(expr_kind other) ~loc:expr.exp_loc

let parse_value_binding (binding : value_binding) =
  let name = parse_binding_name binding.vb_pat in
  let body = parse_expr binding.vb_expr in
  { name; body }

let parse_structure_item (item : structure_item) =
  match item.str_desc with
  | Tstr_value (Nonrecursive, [ binding ]) -> [ parse_value_binding binding ]
  | Tstr_value (Recursive, _) ->
      unsupported ~node_kind:"Tstr_value(recursive)" ~loc:item.str_loc
  | Tstr_value (_, []) ->
      unsupported ~node_kind:"Tstr_value(empty)" ~loc:item.str_loc
  | Tstr_value (_, _ :: _ :: _) ->
      unsupported ~node_kind:"Tstr_value(and)" ~loc:item.str_loc
  | other ->
      unsupported ~node_kind:(structure_item_kind other) ~loc:item.str_loc

let of_structure (structure : structure) =
  Module (List.concat_map parse_structure_item structure.str_items)
