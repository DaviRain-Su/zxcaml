(* Typedtree subset checker for the ZxCaml frontend.

   This module consumes the fully typed OCaml Typedtree loaded from a .cmt
   file, accepts the current frontend subset, and reports the first
   unsupported Typedtree node as a JSON-friendly diagnostic. *)

open Asttypes
open Typedtree

module StringSet = Set.Make (String)

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
  guard : expr option;
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

type type_expr =
  | Type_var of string
  | Type_constr of type_constr
  | Type_tuple of type_expr list

and type_constr = {
  type_name : string;
  args : type_expr list;
  is_recursive_ref : bool;
}

type type_variant = {
  constr_name : string;
  payload_types : type_expr list;
}

type value_decl = {
  name : string;
  body : expr;
  is_rec : bool;
}

type type_decl = {
  type_name : string;
  params : string list;
  variants : type_variant list;
  is_recursive : bool;
}

type decl =
  | Let_decl of value_decl
  | Type_decl of type_decl

type modul = Module of decl list

exception Unsupported of diagnostic

type type_env = { constructors : StringSet.t }

let builtin_constructor_names = [ "None"; "Some"; "Ok"; "Error"; "[]"; "::" ]

let initial_type_env =
  {
    constructors =
      List.fold_left
        (fun constructors name -> StringSet.add name constructors)
        StringSet.empty builtin_constructor_names;
  }

let type_env_has_constructor env name = StringSet.mem name env.constructors

let type_env_add_variant env variant =
  { constructors = StringSet.add variant.constr_name env.constructors }

let type_env_add_type_decl env type_decl =
  List.fold_left type_env_add_variant env type_decl.variants

let type_env_add_type_decls env type_decls =
  List.fold_left type_env_add_type_decl env type_decls

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

let core_type_kind (ctyp : core_type) =
  match ctyp.ctyp_desc with
  | Ttyp_any -> "Ttyp_any"
  | Ttyp_var _ -> "Ttyp_var"
  | Ttyp_arrow _ -> "Ttyp_arrow"
  | Ttyp_tuple _ -> "Ttyp_tuple"
  | Ttyp_constr _ -> "Ttyp_constr"
  | Ttyp_object _ -> "Ttyp_object"
  | Ttyp_class _ -> "Ttyp_class"
  | Ttyp_alias _ -> "Ttyp_alias"
  | Ttyp_variant _ -> "Ttyp_variant"
  | Ttyp_poly _ -> "Ttyp_poly"
  | Ttyp_package _ -> "Ttyp_package"
  | Ttyp_open _ -> "Ttyp_open"

let ident_name ident = Ident.name ident

let longident_name (lid : Longident.t Location.loc) = Longident.last lid.txt

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

let rec parse_match_scrutinee env (expr : expression) =
  match expr.exp_desc with
  | Texp_constant (Const_int n) -> Const_int n
  | Texp_ident (_, lid, _) -> Var (longident_name lid)
  | Texp_construct (_lid, constructor, args) ->
      let name = constructor.Types.cstr_name in
      if type_env_has_constructor env name then
        Ctor { name; args = List.map (parse_match_scrutinee env) args }
      else unsupported ~node_kind:("Texp_construct(" ^ name ^ ")") ~loc:expr.exp_loc ()
  | other -> unsupported ~node_kind:(expr_kind other) ~loc:expr.exp_loc ()

let rec parse_match_pattern env (pat : pattern) =
  match pat.pat_desc with
  | Tpat_any -> Pat_any
  | Tpat_var (ident, _, _) -> Pat_var (ident_name ident)
  | Tpat_construct (_lid, constructor, args, _) ->
      let name = constructor.Types.cstr_name in
      if type_env_has_constructor env name then
        Pat_ctor { name; args = List.map (parse_match_pattern env) args }
      else unsupported ~node_kind:("Tpat_construct(" ^ name ^ ")") ~loc:pat.pat_loc ()
  | other -> unsupported ~node_kind:(pat_kind other) ~loc:pat.pat_loc ()

let parse_computation_pattern env (pat : computation general_pattern) =
  match pat.pat_desc with
  | Tpat_value value_pat -> parse_match_pattern env (value_pat :> pattern)
  | other -> unsupported ~node_kind:(pat_kind other) ~loc:pat.pat_loc ()

let rec parse_match_case env (case : computation case) =
  let pattern = parse_computation_pattern env case.c_lhs in
  let guard = Option.map (parse_expr env) case.c_guard in
  let body = parse_expr env case.c_rhs in
  { pattern; guard; body }

and parse_apply_args env args =
  let parse_one = function
    | Nolabel, Some arg -> parse_expr env arg
    | _, Some arg -> unsupported ~node_kind:"labelled-application" ~loc:arg.exp_loc ()
    | _, None -> unsupported ~node_kind:"partial-application" ~loc:Location.none ()
  in
  List.map parse_one args

and parse_expr env (expr : expression) =
  match expr.exp_desc with
  | Texp_constant (Const_int n) -> Const_int n
  | Texp_constant (Const_string (value, _, _)) -> Const_string value
  | Texp_ident (_, lid, _) -> Var (longident_name lid)
  | Texp_function ([ param ], Tfunction_body body) ->
      let param = parse_param param in
      let body = parse_expr env body in
      Lambda { params = [ param ]; body }
  | Texp_function (_params, Tfunction_body _) ->
      unsupported ~node_kind:"Texp_function" ~loc:expr.exp_loc ()
  | Texp_function (_params, Tfunction_cases _) ->
      unsupported ~node_kind:"Tfunction_cases" ~loc:expr.exp_loc ()
  | Texp_let (Nonrecursive, [ binding ], body) ->
      let name = parse_binding_name binding.vb_pat in
      let value = parse_expr env binding.vb_expr in
      let body = parse_expr env body in
      Let { name; value; body; is_rec = false }
  | Texp_let (Recursive, [ binding ], body) ->
      let name = parse_binding_name binding.vb_pat in
      let value = parse_expr env binding.vb_expr in
      let body = parse_expr env body in
      Let { name; value; body; is_rec = true }
  | Texp_let (_, [], _) ->
      unsupported ~node_kind:"Texp_let(empty)" ~loc:expr.exp_loc ()
  | Texp_let (_, _ :: _ :: _, _) ->
      unsupported ~node_kind:"Texp_let(and)" ~loc:expr.exp_loc ()
  | Texp_constant _ -> unsupported ~node_kind:"Texp_constant" ~loc:expr.exp_loc ()
  | Texp_construct (_lid, constructor, args) ->
      let name = constructor.Types.cstr_name in
      if type_env_has_constructor env name then
        Ctor { name; args = List.map (parse_expr env) args }
      else unsupported ~node_kind:("Texp_construct(" ^ name ^ ")") ~loc:expr.exp_loc ()
  | Texp_apply ({ exp_desc = Texp_ident (_, lid, _) }, args)
    when is_whitelisted_prim (longident_name lid) ->
      Prim { op = longident_name lid; args = parse_apply_args env args }
  | Texp_apply ({ exp_desc = Texp_ident (_, lid, _) }, _args)
    when is_mutation_primitive (longident_name lid) ->
      unsupported_mutation ~feature:(longident_name lid) ~node_kind:"Texp_apply"
        ~loc:expr.exp_loc
  | Texp_apply (callee, args) ->
      App { callee = parse_expr env callee; args = parse_apply_args env args }
  | Texp_ifthenelse (cond, then_branch, Some else_branch) ->
      If
        {
          cond = parse_expr env cond;
          then_branch = parse_expr env then_branch;
          else_branch = parse_expr env else_branch;
        }
  | Texp_ifthenelse (_, _, None) ->
      unsupported ~node_kind:"Texp_ifthenelse(no-else)" ~loc:expr.exp_loc ()
  | Texp_match (scrutinee, cases, _) ->
      let scrutinee = parse_match_scrutinee env scrutinee in
      let arms = List.map (parse_match_case env) cases in
      Match { scrutinee; arms }
  | other -> unsupported ~node_kind:(expr_kind other) ~loc:expr.exp_loc ()

let type_var_name name = "'" ^ name

let rec parse_type_expr ~current_type (ctyp : core_type) =
  match ctyp.ctyp_desc with
  | Ttyp_var name -> Type_var (type_var_name name)
  | Ttyp_tuple items ->
      Type_tuple (List.map (parse_type_expr ~current_type) items)
  | Ttyp_constr (_path, lid, args) ->
      let type_name = longident_name lid in
      Type_constr
        {
          type_name;
          args = List.map (parse_type_expr ~current_type) args;
          is_recursive_ref = String.equal type_name current_type;
        }
  | _ ->
      unsupported ~node_kind:(core_type_kind ctyp) ~loc:ctyp.ctyp_loc
        ~message:
          "only type variables, named type references, and tuple type payloads \
           are supported in P2 M0 ADT declarations"
        ()

let parse_type_param (param, _) =
  match param.ctyp_desc with
  | Ttyp_var name -> type_var_name name
  | _ ->
      unsupported ~node_kind:(core_type_kind param) ~loc:param.ctyp_loc
        ~message:
          "only simple type-variable parameters are supported in P2 M0 ADT \
           declarations"
        ()

let rec type_expr_has_recursive_ref = function
  | Type_var _ -> false
  | Type_constr constr ->
      constr.is_recursive_ref
      || List.exists type_expr_has_recursive_ref constr.args
  | Type_tuple items -> List.exists type_expr_has_recursive_ref items

let variant_has_recursive_ref variant =
  List.exists type_expr_has_recursive_ref variant.payload_types

let parse_constructor_decl ~current_type (constructor : constructor_declaration) =
  (match constructor.cd_res with
  | None -> ()
  | Some res ->
      unsupported ~node_kind:"GADT-constructor" ~loc:res.ctyp_loc
        ~message:"GADT-style constructor result types are not supported in P2 M0"
        ());
  (match constructor.cd_vars with
  | [] -> ()
  | var :: _ ->
      unsupported ~node_kind:"existential-constructor" ~loc:var.loc
        ~message:"existential constructor variables are not supported in P2 M0"
        ());
  let payload_types =
    match constructor.cd_args with
    | Cstr_tuple args -> List.map (parse_type_expr ~current_type) args
    | Cstr_record _ ->
        unsupported ~node_kind:"Cstr_record" ~loc:constructor.cd_loc
          ~message:"record constructor payloads are not supported until P2 M2"
          ()
  in
  { constr_name = constructor.cd_name.txt; payload_types }

let parse_type_declaration (type_decl : type_declaration) =
  if type_decl.typ_cstrs <> [] then
    unsupported ~node_kind:"type-constraint" ~loc:type_decl.typ_loc
      ~message:"type constraints are not supported in P2 M0 ADT declarations"
      ();
  (match type_decl.typ_private with
  | Public -> ()
  | Private ->
      unsupported ~node_kind:"private-type" ~loc:type_decl.typ_loc
        ~message:"private type declarations are not supported in P2 M0"
        ());
  (match type_decl.typ_manifest with
  | None -> ()
  | Some manifest ->
      unsupported ~node_kind:"type-alias" ~loc:manifest.ctyp_loc
        ~message:"type aliases are not supported in P2 M0 ADT declarations"
        ());
  match type_decl.typ_kind with
  | Ttype_variant constructors ->
      let current_type = type_decl.typ_name.txt in
      let variants =
        List.map (parse_constructor_decl ~current_type) constructors
      in
      Type_decl
        {
          type_name = current_type;
          params = List.map parse_type_param type_decl.typ_params;
          variants;
          is_recursive = List.exists variant_has_recursive_ref variants;
        }
  | Ttype_record _ ->
      unsupported ~node_kind:"Ttype_record" ~loc:type_decl.typ_loc
        ~message:"record type declarations are not supported until P2 M2"
        ()
  | Ttype_abstract ->
      unsupported ~node_kind:"Ttype_abstract" ~loc:type_decl.typ_loc
        ~message:"abstract type declarations are not supported in P2 M0"
        ()
  | Ttype_open ->
      unsupported ~node_kind:"Ttype_open" ~loc:type_decl.typ_loc
        ~message:"open type declarations are not supported in P2 M0"
        ()


let parse_value_binding env (binding : value_binding) =
  let name = parse_binding_name binding.vb_pat in
  let body = parse_expr env binding.vb_expr in
  Let_decl { name; body; is_rec = false }

let parse_structure_item env (item : structure_item) =
  match item.str_desc with
  | Tstr_value (Nonrecursive, [ binding ]) ->
      (env, [ parse_value_binding env binding ])
  | Tstr_value (Recursive, [ binding ]) ->
      let decl =
        match parse_value_binding env binding with
        | Let_decl decl -> Let_decl { decl with is_rec = true }
        | Type_decl _ -> assert false
      in
      (env, [ decl ])
  | Tstr_type (_, declarations) ->
      let decls = List.map parse_type_declaration declarations in
      let type_decls =
        List.map
          (function Type_decl type_decl -> type_decl | Let_decl _ -> assert false)
          decls
      in
      (type_env_add_type_decls env type_decls, decls)
  | Tstr_value (_, []) ->
      unsupported ~node_kind:"Tstr_value(empty)" ~loc:item.str_loc ()
  | Tstr_value (_, _ :: _ :: _) ->
      unsupported ~node_kind:"Tstr_value(and)" ~loc:item.str_loc ()
  | other ->
      unsupported ~node_kind:(structure_item_kind other) ~loc:item.str_loc ()

let of_structure (structure : structure) =
  let _env, decls =
    List.fold_left
      (fun (env, acc) item ->
        let env, item_decls = parse_structure_item env item in
        (env, List.rev_append item_decls acc))
      (initial_type_env, []) structure.str_items
  in
  Module (List.rev decls)
