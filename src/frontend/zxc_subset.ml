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
  | Tuple of expr list
  | Tuple_project of tuple_project
  | Record of record_expr
  | Field_access of field_access
  | Record_update of record_update
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

and tuple_project = {
  tuple_expr : expr;
  index : int;
}

and record_expr = {
  fields : record_expr_field list;
}

and record_expr_field = {
  field_name : string;
  field_value : expr;
}

and field_access = {
  record_expr : expr;
  field_name : string;
}

and record_update = {
  base_expr : expr;
  fields : record_expr_field list;
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
  | Pat_tuple of match_pattern list
  | Pat_record of record_pattern_field list

and ctor_pattern = {
  name : string;
  args : match_pattern list;
}

and record_pattern_field = {
  pattern_field_name : string;
  pattern_field_value : match_pattern;
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

type tuple_type_decl = {
  tuple_type_name : string;
  tuple_params : string list;
  tuple_items : type_expr list;
  tuple_is_recursive : bool;
}

type record_type_field = {
  record_field_name : string;
  record_field_type : type_expr;
  record_field_mutable : bool;
}

type record_type_decl = {
  record_type_name : string;
  record_params : string list;
  record_fields : record_type_field list;
  record_is_recursive : bool;
  record_is_account : bool;
}

type external_type_expr =
  | External_type_constr of external_type_constr
  | External_type_tuple of external_type_expr list
  | External_type_arrow of external_type_expr * external_type_expr

and external_type_constr = {
  external_type_name : string;
  external_type_args : external_type_expr list;
}

type external_decl = {
  external_name : string;
  external_type : external_type_expr;
  external_symbol : string;
}

type decl =
  | Let_decl of value_decl
  | Type_decl of type_decl
  | Tuple_type_decl of tuple_type_decl
  | Record_type_decl of record_type_decl
  | External_decl of external_decl

type modul = Module of decl list

exception Unsupported of diagnostic

type type_env = { constructors : StringSet.t }

let builtin_constructor_names =
  [ "None"; "Some"; "Ok"; "Error"; "[]"; "::"; "true"; "false"; "()" ]

let builtin_account_field_names =
  StringSet.of_list
    [
      "key";
      "lamports";
      "data";
      "owner";
      "is_signer";
      "is_writable";
      "executable";
    ]

let builtin_account_meta_field_names =
  StringSet.of_list [ "pubkey"; "is_writable"; "is_signer" ]

let builtin_instruction_field_names =
  StringSet.of_list [ "program_id"; "accounts"; "data" ]

let builtin_error_field_names =
  StringSet.of_list [ "program_id_index"; "code" ]

let builtin_clock_field_names =
  StringSet.of_list
    [
      "slot";
      "epoch_start_timestamp";
      "epoch";
      "leader_schedule_epoch";
      "unix_timestamp";
    ]

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

let builtin_type_ref name =
  Type_constr { type_name = name; args = []; is_recursive_ref = false }

let builtin_record_field name ty =
  { record_field_name = name; record_field_type = ty; record_field_mutable = false }

let builtin_account_record_decl =
  Record_type_decl
    {
      record_type_name = "account";
      record_params = [];
      record_fields =
        [
          builtin_record_field "key" (builtin_type_ref "bytes");
          builtin_record_field "lamports" (builtin_type_ref "int");
          builtin_record_field "data" (builtin_type_ref "bytes");
          builtin_record_field "owner" (builtin_type_ref "bytes");
          builtin_record_field "is_signer" (builtin_type_ref "bool");
          builtin_record_field "is_writable" (builtin_type_ref "bool");
          builtin_record_field "executable" (builtin_type_ref "bool");
        ];
      record_is_recursive = false;
      record_is_account = false;
    }

let builtin_account_meta_record_decl =
  Record_type_decl
    {
      record_type_name = "account_meta";
      record_params = [];
      record_fields =
        [
          builtin_record_field "pubkey" (builtin_type_ref "bytes");
          builtin_record_field "is_writable" (builtin_type_ref "bool");
          builtin_record_field "is_signer" (builtin_type_ref "bool");
        ];
      record_is_recursive = false;
      record_is_account = false;
    }

let builtin_instruction_record_decl =
  Record_type_decl
    {
      record_type_name = "instruction";
      record_params = [];
      record_fields =
        [
          builtin_record_field "program_id" (builtin_type_ref "bytes");
          builtin_record_field "accounts"
            (Type_constr
               {
                 type_name = "array";
                 args = [ builtin_type_ref "account_meta" ];
                 is_recursive_ref = false;
               });
          builtin_record_field "data" (builtin_type_ref "bytes");
        ];
      record_is_recursive = false;
      record_is_account = false;
    }

let builtin_error_record_decl =
  Record_type_decl
    {
      record_type_name = "error";
      record_params = [];
      record_fields =
        [
          builtin_record_field "program_id_index" (builtin_type_ref "int");
          builtin_record_field "code" (builtin_type_ref "int");
        ];
      record_is_recursive = false;
      record_is_account = false;
    }

let builtin_clock_record_decl =
  Record_type_decl
    {
      record_type_name = "clock";
      record_params = [];
      record_fields =
        [
          builtin_record_field "slot" (builtin_type_ref "int");
          builtin_record_field "epoch_start_timestamp" (builtin_type_ref "int");
          builtin_record_field "epoch" (builtin_type_ref "int");
          builtin_record_field "leader_schedule_epoch" (builtin_type_ref "int");
          builtin_record_field "unix_timestamp" (builtin_type_ref "int");
        ];
      record_is_recursive = false;
      record_is_account = false;
    }

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

let longident_last (lid : Longident.t Location.loc) = Longident.last lid.txt

let longident_name (lid : Longident.t Location.loc) =
  let rec parts = function
    | Longident.Lident name -> [ name ]
    | Longident.Ldot (prefix, name) -> parts prefix @ [ name ]
    | Longident.Lapply _ -> [ Longident.last lid.txt ]
  in
  String.concat "." (parts lid.txt)

let is_whitelisted_prim = function
  | "+" | "-" | "*" | "/" | "mod" | "=" | "<>" | "<" | "<=" | ">" | ">=" -> true
  | _ -> false

let is_mutation_primitive = function
  | "ref" | ":=" | "!" -> true
  | _ -> false

let tuple_projection_index = function
  | "fst" -> Some 0
  | "snd" -> Some 1
  | _ -> None

let pubkey_zero_bytes = String.make 32 '\000'

let pubkey_token_program_bytes =
  "\006\221\246\225\215\101\161\147\217\203\225\070\206\235\121\172\028\180\133\237\095\091\055\145\058\140\245\133\126\255\000\169"

let pubkey_constant_expr = function
  | "Pubkey.zero" -> Some (Const_string pubkey_zero_bytes)
  | "Pubkey.token_program" -> Some (Const_string pubkey_token_program_bytes)
  | _ -> None

let hex_nibble ~loc = function
  | '0' .. '9' as c -> Char.code c - Char.code '0'
  | 'a' .. 'f' as c -> 10 + Char.code c - Char.code 'a'
  | 'A' .. 'F' as c -> 10 + Char.code c - Char.code 'A'
  | _ ->
      unsupported ~node_kind:"Pubkey.of_hex" ~loc
        ~message:"Pubkey.of_hex requires only hexadecimal characters"
        ()

let decode_pubkey_hex_literal ~loc value =
  if String.length value <> 64 then
    unsupported ~node_kind:"Pubkey.of_hex" ~loc
      ~message:"Pubkey.of_hex requires exactly 64 hexadecimal characters"
      ();
  String.init 32 (fun index ->
      let high = hex_nibble ~loc value.[index * 2] in
      let low = hex_nibble ~loc value.[(index * 2) + 1] in
      Char.chr ((high * 16) + low))

let parse_pubkey_of_hex_args args ~loc =
  match args with
  | [ Nolabel, Some { exp_desc = Texp_constant (Const_string (value, _, _)); _ } ] ->
      Const_string (decode_pubkey_hex_literal ~loc value)
  | [ Nolabel, Some arg ] ->
      unsupported ~node_kind:"Pubkey.of_hex" ~loc:arg.exp_loc
        ~message:"Pubkey.of_hex requires a hex string literal argument"
        ()
  | [ _, Some arg ] ->
      unsupported ~node_kind:"labelled-application" ~loc:arg.exp_loc ()
  | [ _, None ] -> unsupported ~node_kind:"partial-application" ~loc ()
  | _ ->
      unsupported ~node_kind:"Pubkey.of_hex-arity" ~loc
        ~message:"Pubkey.of_hex requires exactly one unlabeled argument"
        ()

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
  | Texp_constant (Const_string (value, _, _)) -> Const_string value
  | Texp_ident (_, lid, _) -> Var (longident_name lid)
  | Texp_construct (_lid, constructor, args) ->
      let name = constructor.Types.cstr_name in
      if type_env_has_constructor env name then
        Ctor { name; args = List.map (parse_match_scrutinee env) args }
      else unsupported ~node_kind:("Texp_construct(" ^ name ^ ")") ~loc:expr.exp_loc ()
  | Texp_tuple items -> Tuple (List.map (parse_match_scrutinee env) items)
  | Texp_field (record_expr, _lid, label) ->
      Field_access
        {
          record_expr = parse_match_scrutinee env record_expr;
          field_name = label.Types.lbl_name;
        }
  | other -> unsupported ~node_kind:(expr_kind other) ~loc:expr.exp_loc ()

let rec parse_match_pattern env (pat : pattern) =
  match pat.pat_desc with
  | Tpat_any -> Pat_any
  | Tpat_var (ident, _, _) -> Pat_var (ident_name ident)
  | Tpat_tuple items -> Pat_tuple (List.map (parse_match_pattern env) items)
  | Tpat_record (fields, _) ->
      Pat_record
        (List.map
           (fun (_lid, label, field_pattern) ->
             {
               pattern_field_name = label.Types.lbl_name;
               pattern_field_value =
                 parse_match_pattern env (field_pattern :> pattern);
             })
           fields)
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

and parse_error_helper_args ~helper args ~loc =
  let parse_one = function
    | Nolabel, Some arg -> arg
    | _, Some arg -> unsupported ~node_kind:"labelled-application" ~loc:arg.exp_loc ()
    | _, None -> unsupported ~node_kind:"partial-application" ~loc:Location.none ()
  in
  match List.map parse_one args with
  | args -> (
      match (helper, args) with
      | ("Error.make" | "Error.encode_code"), [ program_id_index; code ] ->
          (program_id_index, code)
      | _ ->
          unsupported ~node_kind:(helper ^ "-arity") ~loc
            ~message:(helper ^ " requires exactly two unlabeled arguments")
            ())

and parse_error_encode_arg args ~loc =
  match args with
  | [ Nolabel, Some err ] -> err
  | [ _, Some arg ] -> unsupported ~node_kind:"labelled-application" ~loc:arg.exp_loc ()
  | [ _, None ] -> unsupported ~node_kind:"partial-application" ~loc ()
  | _ ->
      unsupported ~node_kind:"Error.encode-arity" ~loc
        ~message:"Error.encode requires exactly one unlabeled argument"
        ()

and validate_error_code_literal code_expr =
  match code_expr.exp_desc with
  | Texp_constant (Const_int code) when code < 0 || code > 255 ->
      unsupported ~node_kind:"Error.code" ~loc:code_expr.exp_loc
        ~message:
          "program-specific error codes must be integer values in the 0-255 range"
        ()
  | _ -> ()

and error_encoding_expr program_id_index code =
  Prim
    {
      op = "+";
      args =
        [
          Prim { op = "*"; args = [ program_id_index; Const_int 256 ] };
          code;
        ];
    }

and parse_error_make env args ~loc =
  let program_id_index, code = parse_error_helper_args ~helper:"Error.make" args ~loc in
  validate_error_code_literal code;
  Record
    {
      fields =
        [
          {
            field_name = "program_id_index";
            field_value = parse_expr env program_id_index;
          };
          { field_name = "code"; field_value = parse_expr env code };
        ];
    }

and parse_error_encode_code env args ~loc =
  let program_id_index, code =
    parse_error_helper_args ~helper:"Error.encode_code" args ~loc
  in
  validate_error_code_literal code;
  error_encoding_expr (parse_expr env program_id_index) (parse_expr env code)

and parse_error_encode env args ~loc =
  let err = parse_expr env (parse_error_encode_arg args ~loc) in
  error_encoding_expr
    (Field_access { record_expr = err; field_name = "program_id_index" })
    (Field_access { record_expr = err; field_name = "code" })

and parse_tuple_projection_args env ~index args ~loc =
  match args with
  | [ Nolabel, Some arg ] -> Tuple_project { tuple_expr = parse_expr env arg; index }
  | [ _, Some arg ] -> unsupported ~node_kind:"labelled-application" ~loc:arg.exp_loc ()
  | [ _, None ] -> unsupported ~node_kind:"partial-application" ~loc ()
  | _ ->
      unsupported ~node_kind:"tuple-projection-arity" ~loc
        ~message:"tuple projection helpers fst/snd require exactly one argument"
        ()

and parse_record_field_expr env (label, definition) =
  match definition with
  | Overridden (_lid, expr) ->
      Some { field_name = label.Types.lbl_name; field_value = parse_expr env expr }
  | Kept _ -> None

and parse_record_fields env fields =
  Array.fold_right
    (fun field acc ->
      match parse_record_field_expr env field with
      | Some field -> field :: acc
      | None -> acc)
    fields []

and parse_expr env (expr : expression) =
  match expr.exp_desc with
  | Texp_constant (Const_int n) -> Const_int n
  | Texp_constant (Const_string (value, _, _)) -> Const_string value
  | Texp_ident (_, lid, _) -> (
      match pubkey_constant_expr (longident_name lid) with
      | Some expr -> expr
      | None -> Var (longident_name lid))
  | Texp_function (params, Tfunction_body body) ->
      let params = List.map parse_param params in
      let body = parse_expr env body in
      Lambda { params; body }
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
  | Texp_tuple items -> Tuple (List.map (parse_expr env) items)
  | Texp_record { fields; extended_expression = None; _ } ->
      Record { fields = parse_record_fields env fields }
  | Texp_record { fields; extended_expression = Some base_expr; _ } ->
      Record_update
        {
          base_expr = parse_expr env base_expr;
          fields = parse_record_fields env fields;
        }
  | Texp_field (record_expr, _lid, label) ->
      Field_access
        { record_expr = parse_expr env record_expr; field_name = label.Types.lbl_name }
  | Texp_apply ({ exp_desc = Texp_ident (_, lid, _) }, args)
    when String.equal (longident_name lid) "Pubkey.of_hex" ->
      parse_pubkey_of_hex_args args ~loc:expr.exp_loc
  | Texp_apply ({ exp_desc = Texp_ident (_, lid, _) }, args)
    when String.equal (longident_name lid) "Error.make" ->
      parse_error_make env args ~loc:expr.exp_loc
  | Texp_apply ({ exp_desc = Texp_ident (_, lid, _) }, args)
    when String.equal (longident_name lid) "Error.encode" ->
      parse_error_encode env args ~loc:expr.exp_loc
  | Texp_apply ({ exp_desc = Texp_ident (_, lid, _) }, args)
    when String.equal (longident_name lid) "Error.encode_code" ->
      parse_error_encode_code env args ~loc:expr.exp_loc
  | Texp_apply ({ exp_desc = Texp_ident (_, lid, _) }, args)
    when is_whitelisted_prim (longident_last lid) ->
      Prim { op = longident_last lid; args = parse_apply_args env args }
  | Texp_apply ({ exp_desc = Texp_ident (_, lid, _) }, _args)
    when is_mutation_primitive (longident_last lid) ->
      unsupported_mutation ~feature:(longident_last lid) ~node_kind:"Texp_apply"
        ~loc:expr.exp_loc
  | Texp_apply ({ exp_desc = Texp_ident (_, lid, _) }, args) -> (
      match tuple_projection_index (longident_last lid) with
      | Some index -> parse_tuple_projection_args env ~index args ~loc:expr.exp_loc
      | None -> App { callee = Var (longident_name lid); args = parse_apply_args env args })
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
  | Ttyp_poly ([], inner) -> parse_type_expr ~current_type inner
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

let record_field_has_recursive_ref field =
  type_expr_has_recursive_ref field.record_field_type

let parse_type_params params = List.map parse_type_param params

let is_account_attribute (attr : Parsetree.attribute) =
  String.equal attr.attr_name.txt "account"

let has_account_attribute attrs = List.exists is_account_attribute attrs

let validate_account_attributes ~loc attrs =
  List.iter
    (fun (attr : Parsetree.attribute) ->
      if is_account_attribute attr then
        match attr.attr_payload with
        | PStr [] -> ()
        | _ ->
            unsupported ~node_kind:"account-attribute" ~loc
              ~message:"[@account] declarations do not take a payload" ())
    attrs

let validate_error_enum_constructor ~current_type constructor =
  if String.equal current_type "error" then
    match constructor.cd_args with
    | Cstr_tuple [] -> ()
    | _ ->
        unsupported ~node_kind:"error-constructor-payload" ~loc:constructor.cd_loc
          ~message:
            "program-specific error enum constructors must not carry payloads"
          ()

let validate_error_enum_size ~current_type ~loc constructors =
  if String.equal current_type "error" && List.length constructors > 256 then
    unsupported ~node_kind:"error-enum-range" ~loc
      ~message:"program-specific error enums may define at most 256 codes"
      ()

let parse_constructor_decl ~current_type (constructor : constructor_declaration) =
  validate_error_enum_constructor ~current_type constructor;
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
      ~message:"type constraints are not supported in P2 type declarations"
      ();
  (match type_decl.typ_private with
  | Public -> ()
  | Private ->
      unsupported ~node_kind:"private-type" ~loc:type_decl.typ_loc
        ~message:"private type declarations are not supported in P2"
        ());
  match type_decl.typ_kind with
  | Ttype_variant constructors ->
      validate_error_enum_size ~current_type:type_decl.typ_name.txt
        ~loc:type_decl.typ_loc constructors;
      (match type_decl.typ_manifest with
      | None -> ()
      | Some manifest ->
          unsupported ~node_kind:"type-alias" ~loc:manifest.ctyp_loc
            ~message:"variant declarations with manifests are not supported in P2"
            ());
      let current_type = type_decl.typ_name.txt in
      let variants =
        List.map (parse_constructor_decl ~current_type) constructors
      in
      Type_decl
        {
          type_name = current_type;
          params = parse_type_params type_decl.typ_params;
          variants;
          is_recursive = List.exists variant_has_recursive_ref variants;
        }
  | Ttype_record fields ->
      validate_account_attributes ~loc:type_decl.typ_loc type_decl.typ_attributes;
      (match type_decl.typ_manifest with
      | None -> ()
      | Some manifest ->
          unsupported ~node_kind:"type-alias" ~loc:manifest.ctyp_loc
            ~message:"record declarations with manifests are not supported in P2"
            ());
      let current_type = type_decl.typ_name.txt in
      let record_fields =
        List.map
          (fun field ->
            {
              record_field_name = field.ld_name.txt;
              record_field_type = parse_type_expr ~current_type field.ld_type;
              record_field_mutable = (field.ld_mutable = Mutable);
            })
          fields
      in
      Record_type_decl
        {
          record_type_name = current_type;
          record_params = parse_type_params type_decl.typ_params;
          record_fields;
          record_is_recursive =
            List.exists record_field_has_recursive_ref record_fields;
          record_is_account =
            has_account_attribute type_decl.typ_attributes;
        }
  | Ttype_abstract -> (
      match type_decl.typ_manifest with
      | Some { ctyp_desc = Ttyp_tuple items; _ } ->
          let current_type = type_decl.typ_name.txt in
          let tuple_items = List.map (parse_type_expr ~current_type) items in
          Tuple_type_decl
            {
              tuple_type_name = current_type;
              tuple_params = parse_type_params type_decl.typ_params;
              tuple_items;
              tuple_is_recursive =
                List.exists type_expr_has_recursive_ref tuple_items;
            }
      | Some manifest ->
          unsupported ~node_kind:(core_type_kind manifest) ~loc:manifest.ctyp_loc
            ~message:"only tuple type aliases are supported in P2 M2"
            ()
      | None ->
          unsupported ~node_kind:"Ttype_abstract" ~loc:type_decl.typ_loc
            ~message:"abstract type declarations are not supported in P2"
            ())
  | Ttype_open ->
      unsupported ~node_kind:"Ttype_open" ~loc:type_decl.typ_loc
        ~message:"open type declarations are not supported in P2"
        ()

let rec parse_external_type_expr (ctyp : core_type) =
  match ctyp.ctyp_desc with
  | Ttyp_constr (_path, lid, args) ->
      External_type_constr
        {
          external_type_name = longident_name lid;
          external_type_args = List.map parse_external_type_expr args;
        }
  | Ttyp_tuple items -> External_type_tuple (List.map parse_external_type_expr items)
  | Ttyp_arrow (Nolabel, arg, result) ->
      External_type_arrow
        (parse_external_type_expr arg, parse_external_type_expr result)
  | Ttyp_arrow (_, _, _) ->
      unsupported ~node_kind:"labelled-external-type" ~loc:ctyp.ctyp_loc
        ~message:"external declarations only support unlabeled function arrows"
        ()
  | Ttyp_poly ([], inner) -> parse_external_type_expr inner
  | Ttyp_var _ | Ttyp_any ->
      unsupported ~node_kind:(core_type_kind ctyp) ~loc:ctyp.ctyp_loc
        ~message:
          "polymorphic external declarations are not supported in the ZxCaml \
           wire format"
        ()
  | _ ->
      unsupported ~node_kind:(core_type_kind ctyp) ~loc:ctyp.ctyp_loc
        ~message:
          "external declarations only support named types, tuples, and \
           unlabeled function arrows"
        ()

let parse_external_symbol ~loc = function
  | [ symbol ] ->
      if symbol <> "" then symbol
      else
        unsupported ~node_kind:"external-symbol" ~loc
          ~message:"external declarations require a non-empty symbol string"
          ()
  | [] ->
      unsupported ~node_kind:"external-symbol" ~loc
        ~message:"external declarations require exactly one symbol string"
        ()
  | _ :: _ :: _ ->
      unsupported ~node_kind:"external-symbol" ~loc
        ~message:"external declarations with separate bytecode/native symbols are not supported"
        ()

let parse_external_decl (value : value_description) =
  External_decl
    {
      external_name = value.val_name.txt;
      external_type = parse_external_type_expr value.val_desc;
      external_symbol = parse_external_symbol ~loc:value.val_loc value.val_prim;
    }

let rec type_expr_uses_type type_name = function
  | Type_var _ -> false
  | Type_tuple items -> List.exists (type_expr_uses_type type_name) items
  | Type_constr constr ->
      String.equal constr.type_name type_name
      || List.exists (type_expr_uses_type type_name) constr.args

let rec external_type_expr_uses_type type_name = function
  | External_type_constr constr ->
      String.equal constr.external_type_name type_name
      || List.exists
           (external_type_expr_uses_type type_name)
           constr.external_type_args
  | External_type_tuple items ->
      List.exists (external_type_expr_uses_type type_name) items
  | External_type_arrow (arg, result) ->
      external_type_expr_uses_type type_name arg
      || external_type_expr_uses_type type_name result

let record_type_field_uses_type type_name field =
  type_expr_uses_type type_name field.record_field_type

let variant_uses_type type_name variant =
  List.exists (type_expr_uses_type type_name) variant.payload_types

let rec expr_uses_record_fields field_names = function
  | Const_int _ | Const_string _ | Var _ -> false
  | Lambda lambda -> expr_uses_record_fields field_names lambda.body
  | App app ->
      expr_uses_record_fields field_names app.callee
      || List.exists (expr_uses_record_fields field_names) app.args
  | Let let_expr ->
      expr_uses_record_fields field_names let_expr.value
      || expr_uses_record_fields field_names let_expr.body
  | If if_expr ->
      expr_uses_record_fields field_names if_expr.cond
      || expr_uses_record_fields field_names if_expr.then_branch
      || expr_uses_record_fields field_names if_expr.else_branch
  | Prim prim -> List.exists (expr_uses_record_fields field_names) prim.args
  | Ctor ctor -> List.exists (expr_uses_record_fields field_names) ctor.args
  | Tuple items -> List.exists (expr_uses_record_fields field_names) items
  | Tuple_project tuple_project ->
      expr_uses_record_fields field_names tuple_project.tuple_expr
  | Record record ->
      List.exists
        (fun field ->
          StringSet.mem field.field_name field_names
          || expr_uses_record_fields field_names field.field_value)
        record.fields
  | Field_access field_access ->
      StringSet.mem field_access.field_name field_names
      || expr_uses_record_fields field_names field_access.record_expr
  | Record_update record_update ->
      expr_uses_record_fields field_names record_update.base_expr
      || List.exists
           (fun field ->
             StringSet.mem field.field_name field_names
             || expr_uses_record_fields field_names field.field_value)
           record_update.fields
  | Match match_expr ->
      expr_uses_record_fields field_names match_expr.scrutinee
      || List.exists (match_arm_uses_record_fields field_names) match_expr.arms

and match_arm_uses_record_fields field_names arm =
  pattern_uses_record_fields field_names arm.pattern
  || Option.fold ~none:false
       ~some:(expr_uses_record_fields field_names)
       arm.guard
  || expr_uses_record_fields field_names arm.body

and pattern_uses_record_fields field_names = function
  | Pat_any | Pat_var _ -> false
  | Pat_ctor ctor -> List.exists (pattern_uses_record_fields field_names) ctor.args
  | Pat_tuple items -> List.exists (pattern_uses_record_fields field_names) items
  | Pat_record fields ->
      List.exists
        (fun field ->
          StringSet.mem field.pattern_field_name field_names
          || pattern_uses_record_fields field_names field.pattern_field_value)
        fields

let decl_defines_record_type type_name = function
  | Record_type_decl decl -> String.equal decl.record_type_name type_name
  | Let_decl _ | Type_decl _ | Tuple_type_decl _ | External_decl _ -> false

let decl_uses_type type_name = function
  | Let_decl _ -> false
  | Type_decl decl -> List.exists (variant_uses_type type_name) decl.variants
  | Tuple_type_decl decl ->
      List.exists (type_expr_uses_type type_name) decl.tuple_items
  | Record_type_decl decl ->
      List.exists (record_type_field_uses_type type_name) decl.record_fields
  | External_decl decl -> external_type_expr_uses_type type_name decl.external_type

let decl_uses_record_fields field_names = function
  | Let_decl decl -> expr_uses_record_fields field_names decl.body
  | Type_decl _ | Tuple_type_decl _ | Record_type_decl _ | External_decl _ -> false

let decl_defines_record_field field_name = function
  | Record_type_decl decl ->
      List.exists
        (fun field -> String.equal field.record_field_name field_name)
        decl.record_fields
  | Let_decl _ | Type_decl _ | Tuple_type_decl _ | External_decl _ -> false

let record_field_used_without_source_decl field_names decls =
  StringSet.exists
    (fun field_name ->
      (not (List.exists (decl_defines_record_field field_name) decls))
      && List.exists
           (decl_uses_record_fields (StringSet.singleton field_name))
           decls)
    field_names

let decls_need_builtin_record ~type_name ~field_names decls =
  (not (List.exists (decl_defines_record_type type_name) decls))
  &&
  (List.exists (decl_uses_type type_name) decls
  || record_field_used_without_source_decl field_names decls)

let add_builtin_record_decls decls =
  let needs_clock =
    decls_need_builtin_record ~type_name:"clock"
      ~field_names:builtin_clock_field_names decls
  in
  let needs_error =
    decls_need_builtin_record ~type_name:"error"
      ~field_names:builtin_error_field_names decls
  in
  let needs_account =
    decls_need_builtin_record ~type_name:"account"
      ~field_names:builtin_account_field_names decls
  in
  let needs_instruction =
    decls_need_builtin_record ~type_name:"instruction"
      ~field_names:builtin_instruction_field_names decls
  in
  let needs_account_meta =
    needs_instruction
    || decls_need_builtin_record ~type_name:"account_meta"
         ~field_names:builtin_account_meta_field_names decls
  in
  let builtins =
    List.filter_map
      (fun (needed, decl) -> if needed then Some decl else None)
      [
        (needs_error, builtin_error_record_decl);
        (needs_account, builtin_account_record_decl);
        (needs_account_meta, builtin_account_meta_record_decl);
        (needs_instruction, builtin_instruction_record_decl);
        (needs_clock, builtin_clock_record_decl);
      ]
  in
  builtins @ decls


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
        | Type_decl _ | Tuple_type_decl _ | Record_type_decl _ | External_decl _ ->
            assert false
      in
      (env, [ decl ])
  | Tstr_type (_, declarations) ->
      let decls = List.map parse_type_declaration declarations in
      let type_decls =
        List.filter_map
          (function Type_decl type_decl -> Some type_decl | _ -> None)
          decls
      in
      (type_env_add_type_decls env type_decls, decls)
  | Tstr_primitive value -> (env, [ parse_external_decl value ])
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
  Module (add_builtin_record_decls (List.rev decls))
