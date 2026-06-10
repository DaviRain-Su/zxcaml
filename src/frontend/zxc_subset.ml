(* Typedtree subset checker for the ZxCaml frontend.

   This module consumes the fully typed OCaml Typedtree loaded from a .cmt
   file, accepts the current frontend subset, and reports the first
   unsupported Typedtree node as a JSON-friendly diagnostic. *)

open Asttypes
open Typedtree

module StringSet = Set.Make (String)
module StringMap = Map.Make (String)

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
  (* Wire 1.6: carries the Typedtree source span of the wrapped expression.
     Inserted centrally by `parse_expr`; synthetic (desugared) expressions
     stay unwrapped. Structural inspections must look through it via
     `strip_located`. *)
  | Located of loc * expr
  | Lambda of lambda
  | App of app
  | Let of let_expr
  | Let_rec_group of let_rec_group
  | If of if_expr
  | Prim of prim
  | Ctor of ctor
  | Tuple of expr list
  | Tuple_project of tuple_project
  | Record of record_expr
  | Field_access of field_access
  | Field_set of field_set
  | Record_update of record_update
  | Assert of expr
  | Match of match_expr
  | Array_lit of expr list
  | Array_get of array_get
  | Array_length of expr
  | Array_set of array_set
  | Array_make of array_make
  (* ADR-015 option C / R10: arena-allocated ref cells. The element type is
     baked at parse time and limited to int / bool / option<int|bool>. *)
  | Ref_make of ref_make
  | Ref_get of expr
  | Ref_set of ref_set

and lambda = {
  params : param list;
  param_types : type_expr option list;
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

and let_rec_group = {
  bindings : let_rec_binding list;
  group_body : expr;
}

and let_rec_binding = {
  rec_name : string;
  rec_params : param list;
  rec_param_types : type_expr option list;
  rec_body : expr;
  rec_loc : loc;
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

and field_set = {
  record_expr : expr;
  field_name : string;
  value : expr;
}

and record_update = {
  base_expr : expr;
  fields : record_expr_field list;
}

and array_get = {
  array_expr : expr;
  index_expr : expr;
}

and array_set = {
  set_array_expr : expr;
  set_index_expr : expr;
  set_value_expr : expr;
}

and array_make = {
  make_size : int;
  make_init : expr;
}

and ref_make = {
  ref_elem_ty : type_expr;
  ref_init : expr;
}

and ref_set = {
  ref_set_target : expr;
  ref_set_value : expr;
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
  | Pat_const of const_pattern
  | Pat_ctor of ctor_pattern
  | Pat_tuple of match_pattern list
  | Pat_record of record_pattern_field list
  | Pat_or of match_pattern list
  | Pat_alias of alias_pattern

and const_pattern =
  | Const_pat_int of int
  | Const_pat_string of string
  | Const_pat_char of char

and ctor_pattern = {
  name : string;
  args : match_pattern list;
}

and alias_pattern = {
  alias_pattern : match_pattern;
  alias_name : string;
}

and record_pattern_field = {
  pattern_field_name : string;
  pattern_field_value : match_pattern;
}

and type_expr =
  | Type_var of string
  | Type_constr of type_constr
  | Type_tuple of type_expr list
  | Type_any

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
  loc : loc;
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

type type_alias_decl = {
  alias_type_name : string;
  alias_params : string list;
  alias_rhs : type_expr;
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
  | Let_rec_group_decl of let_rec_binding list
  | Type_decl of type_decl
  | Tuple_type_decl of tuple_type_decl
  | Record_type_decl of record_type_decl
  | Type_alias_decl of type_alias_decl
  | External_decl of external_decl

type modul = Module of decl list

exception Unsupported of diagnostic

type alias_binding = {
  alias_binding_params : string list;
  alias_binding_rhs : type_expr;
}

type type_env = {
  constructors : StringSet.t;
  aliases : alias_binding StringMap.t;
  user_modules : StringSet.t;
}

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

let builtin_rent_field_names =
  StringSet.of_list
    [ "lamports_per_byte_year"; "exemption_threshold"; "burn_percent" ]

let builtin_instructions_header_field_names =
  StringSet.of_list [ "instruction_count"; "offsets" ]

let builtin_stake_history_entry_field_names =
  StringSet.of_list [ "epoch"; "effective"; "activating"; "deactivating" ]

let builtin_epoch_schedule_field_names =
  StringSet.of_list
    [
      "slots_per_epoch";
      "leader_schedule_slot_offset";
      "warmup";
      "first_normal_epoch";
      "first_normal_slot";
    ]

let initial_type_env =
  {
    constructors =
      List.fold_left
        (fun constructors name -> StringSet.add name constructors)
        StringSet.empty builtin_constructor_names;
    aliases = StringMap.empty;
    user_modules = StringSet.empty;
  }

let type_env_has_constructor env name = StringSet.mem name env.constructors

let type_env_add_variant env variant =
  { env with constructors = StringSet.add variant.constr_name env.constructors }

let type_env_add_type_decl env type_decl =
  List.fold_left type_env_add_variant env type_decl.variants

let type_env_add_type_decls env type_decls =
  List.fold_left type_env_add_type_decl env type_decls

let type_env_add_alias env name params rhs =
  {
    env with
    aliases =
      StringMap.add name
        { alias_binding_params = params; alias_binding_rhs = rhs }
        env.aliases;
  }

let builtin_type_ref name =
  Type_constr { type_name = name; args = []; is_recursive_ref = false }

let builtin_external_type_ref name =
  External_type_constr { external_type_name = name; external_type_args = [] }

let builtin_external_array element =
  External_type_constr
    { external_type_name = "array"; external_type_args = [ element ] }

let builtin_external_arrow arg result = External_type_arrow (arg, result)

let builtin_record_field name ty =
  { record_field_name = name; record_field_type = ty; record_field_mutable = false }

let builtin_crypto_blake3_external_decl =
  External_decl
    {
      external_name = "Crypto.blake3";
      external_type =
        builtin_external_arrow (builtin_external_type_ref "bytes")
          (builtin_external_type_ref "bytes");
      external_symbol = "sol_blake3_alloc";
    }

let builtin_crypto_secp256k1_recover_external_decl =
  External_decl
    {
      external_name = "Crypto.secp256k1_recover";
      external_type =
        builtin_external_arrow (builtin_external_type_ref "bytes")
          (builtin_external_arrow (builtin_external_type_ref "int")
             (builtin_external_arrow (builtin_external_type_ref "bytes")
                (builtin_external_type_ref "bytes")));
      external_symbol = "sol_secp256k1_recover_alloc";
    }

let builtin_sysvar_clock_from_account_external_decl =
  External_decl
    {
      external_name = "Sysvar.clock_from_account";
      external_type =
        builtin_external_arrow (builtin_external_type_ref "bytes")
          (builtin_external_type_ref "clock");
      external_symbol = "sysvar.readClock";
    }

let builtin_sysvar_rent_from_account_external_decl =
  External_decl
    {
      external_name = "Sysvar.rent_from_account";
      external_type =
        builtin_external_arrow (builtin_external_type_ref "bytes")
          (builtin_external_type_ref "rent");
      external_symbol = "sysvar.readRent";
    }

let builtin_sysvar_instructions_header_from_account_external_decl =
  External_decl
    {
      external_name = "Sysvar.instructions_header_from_account";
      external_type =
        builtin_external_arrow (builtin_external_type_ref "bytes")
          (builtin_external_type_ref "instructions_header");
      external_symbol = "sysvar.readInstructionsHeader";
    }

let builtin_sysvar_instruction_at_external_decl =
  External_decl
    {
      external_name = "Sysvar.instruction_at";
      external_type =
        builtin_external_arrow (builtin_external_type_ref "bytes")
          (builtin_external_arrow (builtin_external_type_ref "int")
             (builtin_external_type_ref "instruction"));
      external_symbol = "sysvar.readInstructionAt";
    }

let builtin_sysvar_stake_history_latest_from_account_external_decl =
  External_decl
    {
      external_name = "Sysvar.stake_history_latest_from_account";
      external_type =
        builtin_external_arrow (builtin_external_type_ref "bytes")
          (builtin_external_arrow (builtin_external_type_ref "int")
             (builtin_external_array
                (builtin_external_type_ref "stake_history_entry")));
      external_symbol = "sysvar.readStakeHistory";
    }

let builtin_sysvar_epoch_schedule_from_account_external_decl =
  External_decl
    {
      external_name = "Sysvar.epoch_schedule_from_account";
      external_type =
        builtin_external_arrow (builtin_external_type_ref "bytes")
          (builtin_external_type_ref "epoch_schedule");
      external_symbol = "sysvar.readEpochSchedule";
    }

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

let builtin_rent_record_decl =
  Record_type_decl
    {
      record_type_name = "rent";
      record_params = [];
      record_fields =
        [
          builtin_record_field "lamports_per_byte_year" (builtin_type_ref "int");
          builtin_record_field "exemption_threshold" (builtin_type_ref "int");
          builtin_record_field "burn_percent" (builtin_type_ref "int");
        ];
      record_is_recursive = false;
      record_is_account = false;
    }

let builtin_instructions_header_record_decl =
  Record_type_decl
    {
      record_type_name = "instructions_header";
      record_params = [];
      record_fields =
        [
          builtin_record_field "instruction_count" (builtin_type_ref "int");
          builtin_record_field "offsets"
            (Type_constr
               {
                 type_name = "array";
                 args = [ builtin_type_ref "int" ];
                 is_recursive_ref = false;
               });
        ];
      record_is_recursive = false;
      record_is_account = false;
    }

let builtin_stake_history_entry_record_decl =
  Record_type_decl
    {
      record_type_name = "stake_history_entry";
      record_params = [];
      record_fields =
        [
          builtin_record_field "epoch" (builtin_type_ref "int");
          builtin_record_field "effective" (builtin_type_ref "int");
          builtin_record_field "activating" (builtin_type_ref "int");
          builtin_record_field "deactivating" (builtin_type_ref "int");
        ];
      record_is_recursive = false;
      record_is_account = false;
    }

let builtin_epoch_schedule_record_decl =
  Record_type_decl
    {
      record_type_name = "epoch_schedule";
      record_params = [];
      record_fields =
        [
          builtin_record_field "slots_per_epoch" (builtin_type_ref "int");
          builtin_record_field "leader_schedule_slot_offset" (builtin_type_ref "int");
          builtin_record_field "warmup" (builtin_type_ref "bool");
          builtin_record_field "first_normal_epoch" (builtin_type_ref "int");
          builtin_record_field "first_normal_slot" (builtin_type_ref "int");
        ];
      record_is_recursive = false;
      record_is_account = false;
    }

(* Wire 1.6: looks through `Located` wrappers for structural inspection.
   Use this wherever code matches on the shape of an already-parsed
   expression. *)
let rec strip_located = function
  | Located (_, inner) -> strip_located inner
  | expr -> expr

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

let starts_with ~prefix value =
  let prefix_len = String.length prefix in
  String.length value >= prefix_len && String.sub value 0 prefix_len = prefix

let unsupported_code_and_message node_kind =
  match node_kind with
  | "Texp_variant" ->
      ( "E0010",
        "polymorphic variants are not part of the ZxCaml subset" )
  | "Texp_constant(float)" ->
      ("E0011", "float constants cannot be lowered to BPF")
  | "Texp_constant" ->
      ("E0012", "this constant is not part of the ZxCaml subset")
  | "Texp_apply(mutation)" | "Texp_setfield" | "Texp_instvar"
  | "Texp_setinstvar" | "Texp_override" ->
      ("E0013", "mutable references are not part of the ZxCaml subset")
  | "Texp_pack" | "Texp_letmodule" ->
      ("E0014", "first-class modules are not supported")
  | "Tstr_recmodule" ->
      ("E0015", "recursive modules are not yet supported")
  | "Texp_try" | "Texp_letexception" | "Tstr_exception" ->
      ("E0016", "exceptions are not supported")
  | "Texp_for" | "Texp_while" ->
      (* ADR-015 option D: `for` and `while` are accepted natively and
         desugared into self-recursive `let rec`. This branch is retained
         defensively in case desugaring is bypassed but should not normally
         fire. *)
      ("E0017", "loops are not supported; use recursion or higher-order functions")
  | "Texp_object" | "Texp_new" | "Texp_send" ->
      ("E0018", "objects and method calls are not part of the ZxCaml subset")
  | "Texp_array" ->
      (* ADR-015 option B / R9.2: int array literals + Array.get/length and
         the writing surface (Array.set / Array.make / a.(i) <- v) are
         accepted. This branch remains defensively for the rare unsupported
         shapes (non-literal Array.make size, Array.init, etc.). *)
      ("E0019", "this array form is not part of the ZxCaml subset")
  | "Array.non_int_elem" ->
      ("E0040", "array element type is not `int`; only int arrays are supported in R9.1")
  | "Texp_lazy" ->
      ("E0020", "lazy expressions are not supported")
  | "Texp_letop" ->
      ("E0021", "binding operators are not supported")
  | "Texp_unreachable" ->
      ("E0022", "unreachable expressions are not supported")
  | "Texp_extension_constructor" | "Tstr_typext" ->
      ("E0023", "extension constructors are not part of the ZxCaml subset")
  | node_kind when starts_with ~prefix:"Texp_construct" node_kind ->
      ("E0024", "this constructor is not known to the ZxCaml subset")
  | node_kind when starts_with ~prefix:"Texp_" node_kind ->
      ("E0090", Printf.sprintf "%s is not part of the ZxCaml subset" node_kind)
  | node_kind when starts_with ~prefix:"Tstr_" node_kind ->
      ("E0091", Printf.sprintf "%s declarations are not part of the ZxCaml subset" node_kind)
  | node_kind when starts_with ~prefix:"Tpat_" node_kind ->
      ("E0092", Printf.sprintf "%s patterns are not part of the ZxCaml subset" node_kind)
  | _ ->
      ("E0099", Printf.sprintf "%s is not part of the ZxCaml subset" node_kind)

let unsupported ?code ?message ?hint ~node_kind ~loc () =
  let default_code, default_message = unsupported_code_and_message node_kind in
  raise
    (Unsupported
       {
         severity = "error";
         code = Option.value code ~default:default_code;
         node_kind;
         loc = loc_of_location loc;
         message = Option.value message ~default:default_message;
         hint;
       })

let unsupported_mutation ~feature ~node_kind ~loc =
  unsupported ~node_kind ~loc ~code:"E0013"
    ~message:"mutable references are not part of the ZxCaml subset"
    ~hint:(Printf.sprintf "%s mutates local state; use immutable values instead" feature)
    ()

let unsupported_constant ~loc = function
  | Const_float _ ->
      unsupported ~node_kind:"Texp_constant(float)" ~loc
        ~message:"float constants cannot be lowered to BPF"
        ()
  | _ ->
      unsupported ~node_kind:"Texp_constant" ~loc ()

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

(* ADR-016: a qualified reference to a user-written module file
   (`Foo.helper` with `foo.ml` in the compiled closure) resolves to the
   flat top-level name (`helper`); the joined module is one namespace.
   Anything else keeps the dotted source spelling so the stdlib
   whitelist matching below stays untouched. *)
let resolved_ident_name env (lid : Longident.t Location.loc) =
  match lid.txt with
  | Longident.Ldot (Longident.Lident modname, name)
    when StringSet.mem modname env.user_modules ->
      name
  | _ -> longident_name lid

let is_whitelisted_prim = function
  | "+" | "-" | "*" | "/" | "mod" | "=" | "<>" | "<" | "<=" | ">" | ">=" -> true
  | "land" | "lor" | "lxor" | "lsl" | "lsr" | "lnot" -> true
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

(* R6b.1 labelled-argument whitelist: maps the qualified stdlib callee name
   to the canonical positional order of its labelled parameters as declared
   in `stdlib/core.ml`. Any positional (unlabelled) args at the call site
   follow these labelled args in the order they appear. *)
let labelled_callee_canonical_order = function
  | "Option.fold" -> Some [ "none"; "some" ]
  | _ -> None

let arg_label_name = function
  | Labelled name | Optional name -> Some name
  | Nolabel -> None

let reorder_labelled_args ~callee ~canonical_order args ~loc =
  let labelled, positional =
    List.partition (fun (label, _) -> arg_label_name label <> None) args
  in
  let label_map = Hashtbl.create (List.length labelled) in
  List.iter
    (fun (label, arg_opt) ->
      match arg_label_name label, arg_opt with
      | Some name, Some arg ->
          if Hashtbl.mem label_map name then
            unsupported ~node_kind:"labelled-application" ~loc:arg.exp_loc
              ~code:"E0031"
              ~message:
                (Printf.sprintf
                   "duplicate label `~%s:` in call to %s; each label may appear at most once"
                   name callee)
              ()
          else Hashtbl.add label_map name arg
      | Some name, None ->
          unsupported ~node_kind:"labelled-application" ~loc
            ~code:"E0030"
            ~message:
              (Printf.sprintf
                 "missing required label `~%s:` in call to %s" name callee)
            ()
      | None, _ -> ())
    labelled;
  List.iter
    (fun (label, _) ->
      match arg_label_name label with
      | Some name when not (List.mem name canonical_order) ->
          unsupported ~node_kind:"labelled-application" ~loc
            ~code:"E0031"
            ~message:
              (Printf.sprintf
                 "unknown label `~%s:` for %s; expected one of: %s"
                 name callee
                 (String.concat ", "
                    (List.map (fun n -> "~" ^ n ^ ":") canonical_order)))
            ()
      | _ -> ())
    labelled;
  let ordered_labelled =
    List.map
      (fun name ->
        match Hashtbl.find_opt label_map name with
        | Some arg -> (Nolabel, Some arg)
        | None ->
            unsupported ~node_kind:"labelled-application" ~loc
              ~code:"E0030"
              ~message:
                (Printf.sprintf
                   "missing required label `~%s:` in call to %s" name callee)
              ())
      canonical_order
  in
  ordered_labelled @ positional

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

(* Hygienic name counter for ADR-015 D loop desugaring. The counter is shared
   across one frontend run; each desugared `for`/`while` allocates a fresh
   suffix so nested loops do not collide. *)
let loop_counter = ref 0

let fresh_loop_id () =
  let id = !loop_counter in
  incr loop_counter;
  id

(* R11.5 hygienic name counter for synthetic-let desugaring used when a
   match scrutinee or `let`-destructure right-hand side is not already in
   atom form. The `__zxc_` prefix keeps the synthesized names disjoint
   from user identifiers. *)
let match_scrut_counter = ref 0

let fresh_match_scrut_id () =
  let id = !match_scrut_counter in
  incr match_scrut_counter;
  id

let unit_expr = Ctor { name = "()"; args = [] }

let parse_binding_name (pat : pattern) =
  match pat.pat_desc with
  | Tpat_any -> "_"
  | Tpat_var (ident, _, _) -> ident_name ident
  | Tpat_alias (_, ident, _, _) -> ident_name ident
  | other -> unsupported ~node_kind:(pat_kind other) ~loc:pat.pat_loc ()

(* Best-effort lowering of a fully-instantiated OCaml [Types.type_expr] into the
   wire-format [type_expr] surface. This reuses the same encoding that
   `parse_type_expr_raw` produces for ADT payloads: `(type-var 'a)`,
   `(type-ref name args)`, `(tuple-type ...)`. Anything we cannot encode
   becomes `Type_any` so the bridge knows the type is unconstrained. *)
let rec type_of_ocaml_type_expr (ty : Types.type_expr) : type_expr =
  match Types.get_desc ty with
  | Tvar None -> Type_any
  | Tvar (Some name) -> Type_var ("'" ^ name)
  | Tunivar None -> Type_any
  | Tunivar (Some name) -> Type_var ("'" ^ name)
  | Tlink inner | Tsubst (inner, _) | Tpoly (inner, _) ->
      type_of_ocaml_type_expr inner
  | Ttuple items ->
      Type_tuple (List.map type_of_ocaml_type_expr items)
  | Tconstr (path, args, _) ->
      (* Use [Path.last] so the wire emits unqualified names (e.g. [account]
         rather than [Core.account]); the Core IR lowerer indexes record and
         ADT declarations by their unqualified name. Path-collisions between
         distinct user types from different modules are not a concern in the
         current single-module program model. *)
      let name = Path.last path in
      Type_constr
        {
          type_name = name;
          args = List.map type_of_ocaml_type_expr args;
          is_recursive_ref = false;
        }
  | _ -> Type_any

(* ADR-015 option C / R10: the element type stored in a `ref` cell is
   restricted at the frontend boundary to keep the IR small. This helper
   accepts the supported shapes and rejects everything else with the still-
   active E0013 carrying an R10-specific hint. *)
let is_supported_ref_elem_ty ty =
  let is_simple = function
    | Type_constr { type_name = "int"; args = []; _ }
    | Type_constr { type_name = "bool"; args = []; _ } -> true
    | _ -> false
  in
  match ty with
  | Type_constr { type_name = "int"; args = []; _ }
  | Type_constr { type_name = "bool"; args = []; _ } -> true
  | Type_constr { type_name = "option"; args = [ inner ]; _ } -> is_simple inner
  | _ -> false

let unsupported_ref_elem ~node_kind ~loc =
  unsupported ~node_kind ~loc ~code:"E0013"
    ~message:"this `ref` element type is not part of the ZxCaml subset (R10)"
    ~hint:"R10 accepts `int`, `bool`, and `option` of int/bool ref cells; refs of string/record/list/tuple are deferred"
    ()

(* Extracts the element type from a fully-instantiated `'a ref` OCaml type. *)
let ref_elem_of_ocaml_type (ty : Types.type_expr) : type_expr option =
  let rec strip ty =
    match Types.get_desc ty with
    | Tlink inner | Tsubst (inner, _) | Tpoly (inner, _) -> strip inner
    | other -> other
  in
  match strip ty with
  | Tconstr (path, [ arg ], _) when String.equal (Path.last path) "ref" ->
      Some (type_of_ocaml_type_expr arg)
  | _ -> None

let is_account_ocaml_type (ty : Types.type_expr) =
  match type_of_ocaml_type_expr ty with
  | Type_constr { type_name = "account"; args = []; _ } -> true
  | _ -> false

let parse_param (param : function_param) =
  match (param.fp_arg_label, param.fp_kind) with
  | Nolabel, Tparam_pat pat ->
      let ty = Some (type_of_ocaml_type_expr pat.pat_type) in
      (match pat.pat_desc with
      | Tpat_any -> (Anonymous, ty)
      | Tpat_var (ident, _, _) -> (Param (ident_name ident), ty)
      | Tpat_alias (_, ident, _, _) -> (Param (ident_name ident), ty)
      | other -> unsupported ~node_kind:(pat_kind other) ~loc:pat.pat_loc ())
  | _, Tparam_pat pat ->
      unsupported ~node_kind:"labelled-parameter" ~loc:pat.pat_loc ()
  | _, Tparam_optional_default (pat, _) ->
      unsupported ~node_kind:"optional-parameter" ~loc:pat.pat_loc ()

(* R11.5: returns true for expression forms that may appear directly as a
   match scrutinee or `let`-destructure right-hand side without requiring a
   synthetic-let lift. Anything else is lowered through `parse_expr` and
   then bound to a fresh `__zxc_*` name by the caller. *)
let rec is_scrutinee_atom = function
  | Located (_, inner) -> is_scrutinee_atom inner
  | Const_int _ | Const_string _ | Var _ -> true
  | Ctor { args; _ } -> List.for_all is_scrutinee_atom args
  | Tuple items -> List.for_all is_scrutinee_atom items
  | Field_access { record_expr; _ } -> is_scrutinee_atom record_expr
  | _ -> false

let flatten_or_pattern = function
  | Pat_or alternatives -> alternatives
  | pattern -> [ pattern ]

let rec parse_match_pattern env (pat : pattern) =
  match pat.pat_desc with
  | Tpat_any -> Pat_any
  | Tpat_var (ident, _, _) -> Pat_var (ident_name ident)
  | Tpat_alias (inner, ident, _, _) ->
      Pat_alias
        {
          alias_pattern = parse_match_pattern env (inner :> pattern);
          alias_name = ident_name ident;
        }
  | Tpat_constant (Const_int n) -> Pat_const (Const_pat_int n)
  | Tpat_constant (Const_string (value, _, _)) ->
      Pat_const (Const_pat_string value)
  | Tpat_constant (Const_char value) -> Pat_const (Const_pat_char value)
  | Tpat_or (left, right, None) ->
      let left = parse_match_pattern env (left :> pattern) in
      let right = parse_match_pattern env (right :> pattern) in
      Pat_or (flatten_or_pattern left @ flatten_or_pattern right)
  | Tpat_or (_left, _right, Some _) ->
      unsupported ~node_kind:"Tpat_or(type-pattern)" ~loc:pat.pat_loc
        ~message:"or-patterns derived from #type patterns are not supported"
        ()
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
  | Tpat_constant _ ->
      unsupported ~node_kind:"Tpat_constant" ~loc:pat.pat_loc
        ~message:"only int, string, and char literal patterns are supported"
        ()
  | other -> unsupported ~node_kind:(pat_kind other) ~loc:pat.pat_loc ()

let rec parse_computation_pattern env (pat : computation general_pattern) =
  match pat.pat_desc with
  | Tpat_value value_pat -> parse_match_pattern env (value_pat :> pattern)
  | Tpat_or (left, right, None) ->
      let left = parse_computation_pattern env left in
      let right = parse_computation_pattern env right in
      Pat_or (flatten_or_pattern left @ flatten_or_pattern right)
  | Tpat_or (_left, _right, Some _) ->
      unsupported ~node_kind:"Tpat_or(type-pattern)" ~loc:pat.pat_loc
        ~message:"or-patterns derived from #type patterns are not supported"
        ()
  | other -> unsupported ~node_kind:(pat_kind other) ~loc:pat.pat_loc ()

let rec parse_match_case env (case : computation case) =
  let pattern = parse_computation_pattern env case.c_lhs in
  let guard = Option.map (parse_expr env) case.c_guard in
  let body = parse_expr env case.c_rhs in
  { pattern; guard; body }

and parse_value_match_case env (case : value case) =
  let pattern = parse_match_pattern env case.c_lhs in
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

and split_rec_binding_body body =
  match strip_located body with
  | Lambda lambda -> (lambda.params, lambda.param_types, lambda.body)
  | _ -> ([], [], body)

and parse_let_rec_binding env (binding : value_binding) =
  let rec_name = parse_binding_name binding.vb_pat in
  let rec_params, rec_param_types, rec_body =
    split_rec_binding_body (parse_expr env binding.vb_expr)
  in
  { rec_name; rec_params; rec_param_types; rec_body;
    rec_loc = loc_of_location binding.vb_expr.exp_loc }

and parse_expr env (expr : expression) =
  (* Wire 1.6: centrally wrap every parsed expression with its Typedtree
     span so the bridge can recover expression-level locations. Ghost or
     unknown locations stay unwrapped, as do pass-through cases that
     already carry a (more precise) wrapper. *)
  let inner = parse_expr_unwrapped env expr in
  if expr.exp_loc.Location.loc_ghost then inner
  else
    let lowered = loc_of_location expr.exp_loc in
    if String.equal lowered.file "_unknown_" then inner
    else
      match inner with
      | Located _ -> inner
      | _ -> Located (lowered, inner)

and parse_expr_unwrapped env (expr : expression) =
  match expr.exp_desc with
  | Texp_constant (Const_int n) -> Const_int n
  | Texp_constant (Const_char value) -> Const_int (Char.code value)
  | Texp_constant (Const_string (value, _, _)) -> Const_string value
  | Texp_ident (_, lid, _) -> (
      match pubkey_constant_expr (longident_name lid) with
      | Some expr -> expr
      | None -> Var (resolved_ident_name env lid))
  | Texp_function (params, Tfunction_body body) ->
      let parsed = List.map parse_param params in
      let params = List.map fst parsed in
      let param_types = List.map snd parsed in
      let body = parse_expr env body in
      Lambda { params; param_types; body }
  | Texp_function (params, Tfunction_cases { cases; param; _ }) ->
      let parsed = List.map parse_param params in
      let params = List.map fst parsed @ [ Param (ident_name param) ] in
      let param_types = List.map snd parsed @ [ None ] in
      let body =
        Match
          {
            scrutinee = Var (ident_name param);
            arms = List.map (parse_value_match_case env) cases;
          }
      in
      Lambda { params; param_types; body }
  | Texp_let (Nonrecursive, [ binding ], body) -> (
      (* R11.5: a `let (a, b, ...) = rhs in body` binding is desugared
         into a synthetic `let __zxc_match_scrut_<n> = rhs in match
         __zxc_match_scrut_<n> with (a, b, ...) -> body`. The synthetic
         name keeps the right-hand side evaluated exactly once. Atomic
         right-hand sides skip the temporary so the resulting IR is
         identical to a hand-written `let v = ... in match v with ...`. *)
      match binding.vb_pat.pat_desc with
      | Tpat_tuple _ ->
          let pattern = parse_match_pattern env binding.vb_pat in
          let value = parse_expr env binding.vb_expr in
          let body_expr = parse_expr env body in
          let arm = { pattern; guard = None; body = body_expr } in
          let scrutinee_expr, wrap =
            if is_scrutinee_atom value then (value, fun e -> e)
            else
              let synth_name =
                Printf.sprintf "__zxc_match_scrut_%d"
                  (fresh_match_scrut_id ())
              in
              ( Var synth_name,
                fun match_expr ->
                  Let
                    {
                      name = synth_name;
                      value;
                      body = match_expr;
                      is_rec = false;
                    } )
          in
          wrap (Match { scrutinee = scrutinee_expr; arms = [ arm ] })
      | _ ->
          let name = parse_binding_name binding.vb_pat in
          let value = parse_expr env binding.vb_expr in
          let body = parse_expr env body in
          Let { name; value; body; is_rec = false })
  | Texp_let (Recursive, [ binding ], body) ->
      let name = parse_binding_name binding.vb_pat in
      let value = parse_expr env binding.vb_expr in
      let body = parse_expr env body in
      Let { name; value; body; is_rec = true }
  | Texp_let (Recursive, (_ :: _ :: _ as bindings), body) ->
      Let_rec_group
        {
          bindings = List.map (parse_let_rec_binding env) bindings;
          group_body = parse_expr env body;
        }
  | Texp_let (_, [], _) ->
      unsupported ~node_kind:"Texp_let(empty)" ~loc:expr.exp_loc ()
  | Texp_let (_, _ :: _ :: _, _) ->
      unsupported ~node_kind:"Texp_let(and)" ~loc:expr.exp_loc ()
  | Texp_constant constant -> unsupported_constant ~loc:expr.exp_loc constant
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
  | Texp_setfield (record_expr, _lid, label, value_expr) ->
      if is_account_ocaml_type record_expr.exp_type then
        Field_set
          {
            record_expr = parse_expr env record_expr;
            field_name = label.Types.lbl_name;
            value = parse_expr env value_expr;
          }
      else
        unsupported_mutation ~feature:label.Types.lbl_name ~node_kind:"Texp_setfield"
          ~loc:expr.exp_loc
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
    when (let name = longident_name lid in
          String.equal name "Array.get" || String.equal name "Stdlib.Array.get") -> (
      match parse_apply_args env args with
      | [ array_expr; index_expr ] -> Array_get { array_expr; index_expr }
      | _ ->
          unsupported ~node_kind:"Array.get-arity" ~loc:expr.exp_loc
            ~message:"Array.get requires exactly two unlabeled arguments"
            ())
  | Texp_apply ({ exp_desc = Texp_ident (_, lid, _) }, args)
    when (let name = longident_name lid in
          String.equal name "Array.length" || String.equal name "Stdlib.Array.length") -> (
      match parse_apply_args env args with
      | [ array_expr ] -> Array_length array_expr
      | _ ->
          unsupported ~node_kind:"Array.length-arity" ~loc:expr.exp_loc
            ~message:"Array.length requires exactly one unlabeled argument"
            ())
  | Texp_apply ({ exp_desc = Texp_ident (_, lid, _) }, args)
    when (let name = longident_name lid in
          String.equal name "Array.set" || String.equal name "Stdlib.Array.set"
          || String.equal name "Array.unsafe_set") -> (
      (* ADR-015 option B / R9.2: accept `Array.set a i v` writes. *)
      match parse_apply_args env args with
      | [ array_expr; index_expr; value_expr ] ->
          Array_set
            {
              set_array_expr = array_expr;
              set_index_expr = index_expr;
              set_value_expr = value_expr;
            }
      | _ ->
          unsupported ~node_kind:"Array.set-arity" ~loc:expr.exp_loc
            ~message:"Array.set requires exactly three unlabeled arguments"
            ())
  | Texp_apply ({ exp_desc = Texp_ident (_, lid, _) }, args)
    when (let name = longident_name lid in
          String.equal name "Array.make" || String.equal name "Stdlib.Array.make") -> (
      (* ADR-015 option B / R9.2: accept `Array.make N init` when the size is
         a positive int literal known at parse time. Non-literal sizes still
         raise E0019. *)
      match
        match parse_apply_args env args with
        | [ size_expr; init_expr ] -> [ strip_located size_expr; init_expr ]
        | other -> other
      with
      | [ Const_int n; init_expr ] when n >= 0 ->
          Array_make { make_size = n; make_init = init_expr }
      | [ Const_int _; _ ] ->
          unsupported ~node_kind:"Array.make-negative" ~loc:expr.exp_loc
            ~message:"Array.make requires a non-negative size literal"
            ()
      | [ _; _ ] ->
          unsupported ~node_kind:"Texp_array" ~loc:expr.exp_loc
            ~message:"Array.make's size must be an integer literal in R9.2"
            ~hint:"ADR-015 option B/R9.2 only accepts statically-known sizes; dynamic-size Array.make is deferred"
            ()
      | _ ->
          unsupported ~node_kind:"Array.make-arity" ~loc:expr.exp_loc
            ~message:"Array.make requires exactly two unlabeled arguments"
            ())
  | Texp_apply ({ exp_desc = Texp_ident (_, lid, _) }, _args)
    when (let name = longident_name lid in
          String.equal name "Array.unsafe_get" || String.equal name "Array.init") ->
      unsupported ~node_kind:"Texp_array" ~loc:expr.exp_loc
        ~message:"Array.init / Array.unsafe_get are not part of the ZxCaml subset"
        ~hint:"Use [| ... |], Array.get, Array.length, Array.set, or Array.make instead"
        ()
  | Texp_apply ({ exp_desc = Texp_ident (_, lid, _) }, args)
    when is_whitelisted_prim (longident_last lid) ->
      Prim { op = longident_last lid; args = parse_apply_args env args }
  | Texp_apply ({ exp_desc = Texp_ident (_, lid, _) }, args)
    when is_mutation_primitive (longident_last lid) -> (
      (* ADR-015 option C / R10: desugar `ref e`, `!r`, `r := v` into typed
         ref-cell Core IR nodes. The element type is extracted from the
         OCaml type of the surrounding expression and restricted to the R10
         whitelist; everything else falls through to E0013. *)
      let op = longident_last lid in
      let parsed = parse_apply_args env args in
      match op, parsed with
      | "ref", [ init ] -> (
          let elem_ty = type_of_ocaml_type_expr expr.exp_type in
          let elem_ty =
            match elem_ty with
            | Type_constr { type_name = "ref"; args = [ inner ]; _ } -> inner
            | other -> other
          in
          if not (is_supported_ref_elem_ty elem_ty) then
            unsupported_ref_elem ~node_kind:"Texp_apply(ref)" ~loc:expr.exp_loc;
          Ref_make { ref_elem_ty = elem_ty; ref_init = init })
      | "!", [ target ] ->
          (* Validate the element type via the ref target's OCaml type. *)
          let target_ocaml_ty =
            match args with
            | [ (_, Some arg) ] -> Some arg.exp_type
            | _ -> None
          in
          (match target_ocaml_ty with
           | Some ty -> (
               match ref_elem_of_ocaml_type ty with
               | Some elem_ty ->
                   if not (is_supported_ref_elem_ty elem_ty) then
                     unsupported_ref_elem ~node_kind:"Texp_apply(!)" ~loc:expr.exp_loc
               | None -> ())
           | None -> ());
          Ref_get target
      | ":=", [ target; value ] ->
          let target_ocaml_ty =
            match args with
            | (_, Some arg) :: _ -> Some arg.exp_type
            | _ -> None
          in
          (match target_ocaml_ty with
           | Some ty -> (
               match ref_elem_of_ocaml_type ty with
               | Some elem_ty ->
                   if not (is_supported_ref_elem_ty elem_ty) then
                     unsupported_ref_elem ~node_kind:"Texp_apply(:=)" ~loc:expr.exp_loc
               | None -> ())
           | None -> ());
          Ref_set { ref_set_target = target; ref_set_value = value }
      | _ ->
          unsupported_mutation ~feature:op ~node_kind:"Texp_apply"
            ~loc:expr.exp_loc)
  | Texp_apply ({ exp_desc = Texp_ident (_, lid, _) }, args) -> (
      match tuple_projection_index (longident_last lid) with
      | Some index -> parse_tuple_projection_args env ~index args ~loc:expr.exp_loc
      | None ->
          let callee_name = resolved_ident_name env lid in
          let args =
            match labelled_callee_canonical_order callee_name with
            | Some canonical_order ->
                reorder_labelled_args ~callee:callee_name ~canonical_order args
                  ~loc:expr.exp_loc
            | None -> args
          in
          App { callee = Var callee_name; args = parse_apply_args env args })
  | Texp_apply (callee, args) ->
      App { callee = parse_expr env callee; args = parse_apply_args env args }
  | Texp_ifthenelse (cond, then_branch, Some else_branch) ->
      If
        {
          cond = parse_expr env cond;
          then_branch = parse_expr env then_branch;
          else_branch = parse_expr env else_branch;
        }
  | Texp_ifthenelse (cond, then_branch, None) ->
      If
        {
          cond = parse_expr env cond;
          then_branch = parse_expr env then_branch;
          else_branch = Ctor { name = "()"; args = [] };
        }
  | Texp_match (scrutinee, cases, _) ->
      (* R11.5: lift non-atom scrutinees (e.g. function applications,
         dereferences, `if`/`match`/`let` bodies) into a synthetic
         `__zxc_match_scrut_<n>` binding before the match. Atom-shaped
         scrutinees pass through unchanged so existing sexp output and
         downstream lowering paths stay byte-identical for the common
         case. *)
      let scrutinee_expr = parse_expr env scrutinee in
      let arms = List.map (parse_match_case env) cases in
      if is_scrutinee_atom scrutinee_expr then
        Match { scrutinee = scrutinee_expr; arms }
      else
        let synth_name =
          Printf.sprintf "__zxc_match_scrut_%d" (fresh_match_scrut_id ())
        in
        Let
          {
            name = synth_name;
            value = scrutinee_expr;
            body = Match { scrutinee = Var synth_name; arms };
            is_rec = false;
          }
  | Texp_sequence (first, second) ->
      Let
        {
          name = "_";
          value = parse_expr env first;
          body = parse_expr env second;
          is_rec = false;
        }
  | Texp_assert (condition, _) -> Assert (parse_expr env condition)
  | Texp_for (ident, _pat, lo_expr, hi_expr, direction, body_expr) ->
      (* ADR-015 option D: desugar `for` into a self-recursive `let rec`. The
         recursive helper is tail-called at the back edge so the ANF tail-call
         pass (`src/core/anf/tail.zig`) lowers it to `while (true)` in
         generated Zig.

         Implementation note: the helper returns `int 0` rather than `()` so
         the lowered lambda has an `int` return type. The Zig codegen has
         existing limitations around unit-returning recursive lambdas, and
         the `for`/`while` surface always appears in a value-discard
         position in practice (OCaml's `for` is `unit`, but downstream code
         either wraps with `let _ = ... in ...` or sequences with `;`, both
         of which throw the value away). The discarded `int 0` is observably
         equivalent to a discarded `()`. *)
      let loop_id = fresh_loop_id () in
      let loop_name = Printf.sprintf "__zxc_loop_%d" loop_id in
      let lo_name = Printf.sprintf "__zxc_loop_lo_%d" loop_id in
      let bound_name = Printf.sprintf "__zxc_loop_bound_%d" loop_id in
      let iter_name = ident_name ident in
      let lo_value = parse_expr env lo_expr in
      let hi_value = parse_expr env hi_expr in
      let body_value = parse_expr env body_expr in
      let op_cmp, op_step =
        match direction with
        | Upto -> (">", "+")
        | Downto -> ("<", "-")
      in
      let recursive_call =
        App
          {
            callee = Var loop_name;
            args =
              [
                Prim
                  {
                    op = op_step;
                    args = [ Var iter_name; Const_int 1 ];
                  };
              ];
          }
      in
      let loop_body =
        If
          {
            cond =
              Prim { op = op_cmp; args = [ Var iter_name; Var bound_name ] };
            then_branch = Const_int 0;
            else_branch =
              Let
                {
                  name = "_";
                  value = body_value;
                  body = recursive_call;
                  is_rec = false;
                };
          }
      in
      let loop_lambda =
        Lambda
          {
            params = [ Param iter_name ];
            param_types =
              [ Some (Type_constr { type_name = "int"; args = []; is_recursive_ref = false }) ];
            body = loop_body;
          }
      in
      Let
        {
          name = lo_name;
          value = lo_value;
          body =
            Let
              {
                name = bound_name;
                value = hi_value;
                body =
                  Let
                    {
                      name = loop_name;
                      value = loop_lambda;
                      body =
                        App
                          {
                            callee = Var loop_name;
                            args = [ Var lo_name ];
                          };
                      is_rec = true;
                    };
                is_rec = false;
              };
          is_rec = false;
        }
  | Texp_array elements ->
      (* ADR-015 option B / R9.1: accept `[| ... |]` array literals whose
         elements are `int`-typed expressions. Element type is determined by
         OCaml's inference; we sanity-check using the constant payload shape
         and reject anything we can structurally see is not int via E0040. *)
      let elem_check elem =
        match elem.exp_desc with
        | Texp_constant (Const_string _) ->
            unsupported ~node_kind:"Array.non_int_elem" ~loc:elem.exp_loc
              ~message:"array element type is not `int`; only int arrays are supported in R9.1"
              ()
        | Texp_constant (Const_float _) ->
            unsupported ~node_kind:"Array.non_int_elem" ~loc:elem.exp_loc
              ~message:"array element type is not `int`; only int arrays are supported in R9.1"
              ()
        | _ -> ()
      in
      List.iter elem_check elements;
      Array_lit (List.map (parse_expr env) elements)
  | Texp_while (cond_expr, body_expr) ->
      (* ADR-015 option D: desugar `while cond do body done` into a
         single-argument self-recursive `let rec` whose body re-tests `cond`
         on every iteration. The back-edge tail call is rewritten to
         `while (true)` by the ANF tail-call pass. See the comment on
         `Texp_for` for why the helper returns `int 0` rather than `()`. *)
      let loop_id = fresh_loop_id () in
      let loop_name = Printf.sprintf "__zxc_loop_%d" loop_id in
      let cond_value = parse_expr env cond_expr in
      let body_value = parse_expr env body_expr in
      (* Use an int counter parameter rather than a true unit parameter:
         the OCaml `while` semantics permit any value as long as it is
         discarded by the caller, and using an `int` here sidesteps the
         backend's existing limitation around `unit`/`void` parameter
         lowering. The else branch returns `counter + 0` so the parameter is
         used in an `int` context regardless of whether `cond` is a literal
         (e.g. `while false`). Without this anchor the inferred lambda
         signature defaults to `unit -> ...` when DCE collapses the body. *)
      (* Avoid a leading underscore in the parameter name: the ANF lowerer
         types `_`-prefixed lambda params as `unit`, but we need this counter
         to be `int` so the desugared loop lowers to a clean
         `int -> int` self-recursive function. *)
      let counter_name = Printf.sprintf "zxc_loop_counter_%d" loop_id in
      let recursive_call =
        App
          {
            callee = Var loop_name;
            args =
              [ Prim { op = "+"; args = [ Var counter_name; Const_int 1 ] } ];
          }
      in
      let loop_body =
        If
          {
            cond = cond_value;
            then_branch =
              Let
                {
                  name = "_";
                  value = body_value;
                  body = recursive_call;
                  is_rec = false;
                };
            else_branch =
              Prim { op = "+"; args = [ Var counter_name; Const_int 0 ] };
          }
      in
      let loop_lambda =
        Lambda
          {
            params = [ Param counter_name ];
            param_types =
              [ Some (Type_constr { type_name = "int"; args = []; is_recursive_ref = false }) ];
            body = loop_body;
          }
      in
      Let
        {
          name = loop_name;
          value = loop_lambda;
          body = App { callee = Var loop_name; args = [ Const_int 0 ] };
          is_rec = true;
        }
  | other -> unsupported ~node_kind:(expr_kind other) ~loc:expr.exp_loc ()

let type_var_name name = "'" ^ name

let rec parse_type_expr_raw ~current_type (ctyp : core_type) =
  match ctyp.ctyp_desc with
  | Ttyp_var name -> Type_var (type_var_name name)
  | Ttyp_tuple items ->
      Type_tuple (List.map (parse_type_expr_raw ~current_type) items)
  | Ttyp_constr (_path, lid, args) ->
      let type_name = longident_name lid in
      Type_constr
        {
          type_name;
          args = List.map (parse_type_expr_raw ~current_type) args;
          is_recursive_ref = String.equal type_name current_type;
        }
  | Ttyp_poly ([], inner) -> parse_type_expr_raw ~current_type inner
  | _ ->
      unsupported ~node_kind:(core_type_kind ctyp) ~loc:ctyp.ctyp_loc
        ~message:
          "only type variables, named type references, and tuple type payloads \
           are supported in P2 M0 ADT declarations"
        ()

let rec substitute_type_vars substitutions = function
  | Type_var name as ty -> (
      match StringMap.find_opt name substitutions with
      | Some replacement -> replacement
      | None -> ty)
  | Type_any -> Type_any
  | Type_tuple items -> Type_tuple (List.map (substitute_type_vars substitutions) items)
  | Type_constr constr ->
      Type_constr
        {
          constr with
          args = List.map (substitute_type_vars substitutions) constr.args;
        }

let instantiate_alias binding args =
  let substitutions =
    List.fold_left2
      (fun substitutions param arg -> StringMap.add param arg substitutions)
      StringMap.empty binding.alias_binding_params args
  in
  substitute_type_vars substitutions binding.alias_binding_rhs

let rec resolve_type_aliases env seen = function
  | Type_var _ as ty -> ty
  | Type_any -> Type_any
  | Type_tuple items -> Type_tuple (List.map (resolve_type_aliases env seen) items)
  | Type_constr constr -> (
      let args = List.map (resolve_type_aliases env seen) constr.args in
      match StringMap.find_opt constr.type_name env.aliases with
      | Some binding when not (StringSet.mem constr.type_name seen) ->
          let expanded =
            try instantiate_alias binding args
            with Invalid_argument _ ->
              Type_constr { constr with args }
          in
          resolve_type_aliases env (StringSet.add constr.type_name seen) expanded
      | _ -> Type_constr { constr with args })

let parse_type_expr env ~current_type ctyp =
  parse_type_expr_raw ~current_type ctyp |> resolve_type_aliases env StringSet.empty

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
  | Type_var _ | Type_any -> false
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

let parse_constructor_decl env ~current_type (constructor : constructor_declaration) =
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
    | Cstr_tuple args -> List.map (parse_type_expr env ~current_type) args
    | Cstr_record _ ->
        unsupported ~node_kind:"Cstr_record" ~loc:constructor.cd_loc
          ~message:"record constructor payloads are not supported until P2 M2"
          ()
  in
  { constr_name = constructor.cd_name.txt; payload_types }

let parse_type_declaration env (type_decl : type_declaration) =
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
        List.map (parse_constructor_decl env ~current_type) constructors
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
              record_field_type = parse_type_expr env ~current_type field.ld_type;
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
          let tuple_items = List.map (parse_type_expr env ~current_type) items in
          let tuple_params = parse_type_params type_decl.typ_params in
          if tuple_params = [] then
            Tuple_type_decl
              {
                tuple_type_name = current_type;
                tuple_params;
                tuple_items;
                tuple_is_recursive =
                  List.exists type_expr_has_recursive_ref tuple_items;
              }
          else
            Type_alias_decl
              {
                alias_type_name = current_type;
                alias_params = tuple_params;
                alias_rhs = Type_tuple tuple_items;
              }
      | Some manifest ->
          let current_type = type_decl.typ_name.txt in
          Type_alias_decl
            {
              alias_type_name = current_type;
              alias_params = parse_type_params type_decl.typ_params;
              alias_rhs = parse_type_expr env ~current_type manifest;
            }
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
  | Type_var _ | Type_any -> false
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
  | Located (_, inner) -> expr_uses_record_fields field_names inner
  | Const_int _ | Const_string _ | Var _ -> false
  | Lambda lambda -> expr_uses_record_fields field_names lambda.body
  | App app ->
      expr_uses_record_fields field_names app.callee
      || List.exists (expr_uses_record_fields field_names) app.args
  | Let let_expr ->
      expr_uses_record_fields field_names let_expr.value
      || expr_uses_record_fields field_names let_expr.body
  | Let_rec_group group ->
      List.exists
        (fun binding -> expr_uses_record_fields field_names binding.rec_body)
        group.bindings
      || expr_uses_record_fields field_names group.group_body
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
  | Field_set field_set ->
      StringSet.mem field_set.field_name field_names
      || expr_uses_record_fields field_names field_set.record_expr
      || expr_uses_record_fields field_names field_set.value
  | Record_update record_update ->
      expr_uses_record_fields field_names record_update.base_expr
      || List.exists
           (fun field ->
             StringSet.mem field.field_name field_names
             || expr_uses_record_fields field_names field.field_value)
           record_update.fields
  | Assert condition -> expr_uses_record_fields field_names condition
  | Match match_expr ->
      expr_uses_record_fields field_names match_expr.scrutinee
      || List.exists (match_arm_uses_record_fields field_names) match_expr.arms
  | Array_lit elems ->
      List.exists (expr_uses_record_fields field_names) elems
  | Array_get { array_expr; index_expr } ->
      expr_uses_record_fields field_names array_expr
      || expr_uses_record_fields field_names index_expr
  | Array_length array_expr ->
      expr_uses_record_fields field_names array_expr
  | Array_set { set_array_expr; set_index_expr; set_value_expr } ->
      expr_uses_record_fields field_names set_array_expr
      || expr_uses_record_fields field_names set_index_expr
      || expr_uses_record_fields field_names set_value_expr
  | Array_make { make_size = _; make_init } ->
      expr_uses_record_fields field_names make_init
  | Ref_make { ref_init; _ } ->
      expr_uses_record_fields field_names ref_init
  | Ref_get target -> expr_uses_record_fields field_names target
  | Ref_set { ref_set_target; ref_set_value } ->
      expr_uses_record_fields field_names ref_set_target
      || expr_uses_record_fields field_names ref_set_value

and match_arm_uses_record_fields field_names arm =
  pattern_uses_record_fields field_names arm.pattern
  || Option.fold ~none:false
       ~some:(expr_uses_record_fields field_names)
       arm.guard
  || expr_uses_record_fields field_names arm.body

and pattern_uses_record_fields field_names = function
  | Pat_any | Pat_var _ | Pat_const _ -> false
  | Pat_ctor ctor -> List.exists (pattern_uses_record_fields field_names) ctor.args
  | Pat_tuple items -> List.exists (pattern_uses_record_fields field_names) items
  | Pat_record fields ->
      List.exists
        (fun field ->
          StringSet.mem field.pattern_field_name field_names
          || pattern_uses_record_fields field_names field.pattern_field_value)
        fields
  | Pat_or alternatives ->
      List.exists (pattern_uses_record_fields field_names) alternatives
  | Pat_alias alias ->
      pattern_uses_record_fields field_names alias.alias_pattern

let rec expr_uses_var var_name = function
  | Located (_, inner) -> expr_uses_var var_name inner
  | Var name -> String.equal name var_name
  | Const_int _ | Const_string _ -> false
  | Lambda lambda -> expr_uses_var var_name lambda.body
  | App app ->
      expr_uses_var var_name app.callee
      || List.exists (expr_uses_var var_name) app.args
  | Let let_expr ->
      expr_uses_var var_name let_expr.value
      || expr_uses_var var_name let_expr.body
  | Let_rec_group group ->
      List.exists
        (fun binding -> expr_uses_var var_name binding.rec_body)
        group.bindings
      || expr_uses_var var_name group.group_body
  | If if_expr ->
      expr_uses_var var_name if_expr.cond
      || expr_uses_var var_name if_expr.then_branch
      || expr_uses_var var_name if_expr.else_branch
  | Prim prim -> List.exists (expr_uses_var var_name) prim.args
  | Ctor ctor -> List.exists (expr_uses_var var_name) ctor.args
  | Tuple items -> List.exists (expr_uses_var var_name) items
  | Tuple_project tuple_project -> expr_uses_var var_name tuple_project.tuple_expr
  | Record record ->
      List.exists
        (fun field -> expr_uses_var var_name field.field_value)
        record.fields
  | Field_access field_access -> expr_uses_var var_name field_access.record_expr
  | Field_set field_set ->
      expr_uses_var var_name field_set.record_expr
      || expr_uses_var var_name field_set.value
  | Record_update record_update ->
      expr_uses_var var_name record_update.base_expr
      || List.exists
           (fun field -> expr_uses_var var_name field.field_value)
           record_update.fields
  | Assert condition -> expr_uses_var var_name condition
  | Match match_expr ->
      expr_uses_var var_name match_expr.scrutinee
      || List.exists (match_arm_uses_var var_name) match_expr.arms
  | Array_lit elems -> List.exists (expr_uses_var var_name) elems
  | Array_get { array_expr; index_expr } ->
      expr_uses_var var_name array_expr || expr_uses_var var_name index_expr
  | Array_length array_expr -> expr_uses_var var_name array_expr
  | Array_set { set_array_expr; set_index_expr; set_value_expr } ->
      expr_uses_var var_name set_array_expr
      || expr_uses_var var_name set_index_expr
      || expr_uses_var var_name set_value_expr
  | Array_make { make_size = _; make_init } ->
      expr_uses_var var_name make_init
  | Ref_make { ref_init; _ } -> expr_uses_var var_name ref_init
  | Ref_get target -> expr_uses_var var_name target
  | Ref_set { ref_set_target; ref_set_value } ->
      expr_uses_var var_name ref_set_target || expr_uses_var var_name ref_set_value

and match_arm_uses_var var_name arm =
  Option.fold ~none:false ~some:(expr_uses_var var_name) arm.guard
  || expr_uses_var var_name arm.body

let decl_defines_record_type type_name = function
  | Record_type_decl decl -> String.equal decl.record_type_name type_name
  | Let_decl _ | Let_rec_group_decl _ | Type_decl _ | Tuple_type_decl _
  | Type_alias_decl _ | External_decl _ ->
      false

let decl_uses_type type_name = function
  | Let_decl _ | Let_rec_group_decl _ -> false
  | Type_decl decl -> List.exists (variant_uses_type type_name) decl.variants
  | Tuple_type_decl decl ->
      List.exists (type_expr_uses_type type_name) decl.tuple_items
  | Record_type_decl decl ->
      List.exists (record_type_field_uses_type type_name) decl.record_fields
  | Type_alias_decl decl -> type_expr_uses_type type_name decl.alias_rhs
  | External_decl decl -> external_type_expr_uses_type type_name decl.external_type

let decl_uses_record_fields field_names = function
  | Let_decl decl -> expr_uses_record_fields field_names decl.body
  | Let_rec_group_decl bindings ->
      List.exists
        (fun binding -> expr_uses_record_fields field_names binding.rec_body)
        bindings
  | Type_decl _ | Tuple_type_decl _ | Record_type_decl _ | Type_alias_decl _
  | External_decl _ ->
      false

let decl_defines_external external_name = function
  | External_decl decl -> String.equal decl.external_name external_name
  | Let_decl _ | Let_rec_group_decl _ | Type_decl _ | Tuple_type_decl _
  | Record_type_decl _ | Type_alias_decl _ ->
      false

let decl_uses_var var_name = function
  | Let_decl decl -> expr_uses_var var_name decl.body
  | Let_rec_group_decl bindings ->
      List.exists (fun binding -> expr_uses_var var_name binding.rec_body) bindings
  | Type_decl _ | Tuple_type_decl _ | Record_type_decl _ | Type_alias_decl _
  | External_decl _ ->
      false

let decl_defines_record_field field_name = function
  | Record_type_decl decl ->
      List.exists
        (fun field -> String.equal field.record_field_name field_name)
        decl.record_fields
  | Let_decl _ | Let_rec_group_decl _ | Type_decl _ | Tuple_type_decl _
  | Type_alias_decl _ | External_decl _ ->
      false

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
  let needs_rent =
    decls_need_builtin_record ~type_name:"rent"
      ~field_names:builtin_rent_field_names decls
  in
  let needs_instructions_header =
    decls_need_builtin_record ~type_name:"instructions_header"
      ~field_names:builtin_instructions_header_field_names decls
  in
  let needs_stake_history_entry =
    decls_need_builtin_record ~type_name:"stake_history_entry"
      ~field_names:builtin_stake_history_entry_field_names decls
  in
  let needs_epoch_schedule =
    decls_need_builtin_record ~type_name:"epoch_schedule"
      ~field_names:builtin_epoch_schedule_field_names decls
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
        (needs_rent, builtin_rent_record_decl);
        (needs_instructions_header, builtin_instructions_header_record_decl);
        (needs_stake_history_entry, builtin_stake_history_entry_record_decl);
        (needs_epoch_schedule, builtin_epoch_schedule_record_decl);
      ]
  in
  builtins @ decls

let add_builtin_external_decls decls =
  let needs_blake3 =
    (not (List.exists (decl_defines_external "Crypto.blake3") decls))
    && List.exists (decl_uses_var "Crypto.blake3") decls
  in
  let needs_secp256k1_recover =
    (not (List.exists (decl_defines_external "Crypto.secp256k1_recover") decls))
    && List.exists (decl_uses_var "Crypto.secp256k1_recover") decls
  in
  let needs_sysvar_clock_from_account =
    (not (List.exists (decl_defines_external "Sysvar.clock_from_account") decls))
    && List.exists (decl_uses_var "Sysvar.clock_from_account") decls
  in
  let needs_sysvar_rent_from_account =
    (not (List.exists (decl_defines_external "Sysvar.rent_from_account") decls))
    && List.exists (decl_uses_var "Sysvar.rent_from_account") decls
  in
  let needs_sysvar_instructions_header_from_account =
    (not
       (List.exists
          (decl_defines_external "Sysvar.instructions_header_from_account")
          decls))
    && List.exists (decl_uses_var "Sysvar.instructions_header_from_account") decls
  in
  let needs_sysvar_instruction_at =
    (not (List.exists (decl_defines_external "Sysvar.instruction_at") decls))
    && List.exists (decl_uses_var "Sysvar.instruction_at") decls
  in
  let needs_sysvar_stake_history_latest_from_account =
    (not
       (List.exists
          (decl_defines_external "Sysvar.stake_history_latest_from_account")
          decls))
    && List.exists (decl_uses_var "Sysvar.stake_history_latest_from_account") decls
  in
  let needs_sysvar_epoch_schedule_from_account =
    (not
       (List.exists
          (decl_defines_external "Sysvar.epoch_schedule_from_account")
          decls))
    && List.exists (decl_uses_var "Sysvar.epoch_schedule_from_account") decls
  in
  let builtins =
    List.filter_map
      (fun (needed, decl) -> if needed then Some decl else None)
      [
        (needs_blake3, builtin_crypto_blake3_external_decl);
        (needs_secp256k1_recover, builtin_crypto_secp256k1_recover_external_decl);
        ( needs_sysvar_clock_from_account,
          builtin_sysvar_clock_from_account_external_decl );
        (needs_sysvar_rent_from_account, builtin_sysvar_rent_from_account_external_decl);
        ( needs_sysvar_instructions_header_from_account,
          builtin_sysvar_instructions_header_from_account_external_decl );
        (needs_sysvar_instruction_at, builtin_sysvar_instruction_at_external_decl);
        ( needs_sysvar_stake_history_latest_from_account,
          builtin_sysvar_stake_history_latest_from_account_external_decl );
        ( needs_sysvar_epoch_schedule_from_account,
          builtin_sysvar_epoch_schedule_from_account_external_decl );
      ]
  in
  builtins @ decls


let parse_value_binding env (binding : value_binding) =
  let name = parse_binding_name binding.vb_pat in
  let body = parse_expr env binding.vb_expr in
  Let_decl { name; body; is_rec = false; loc = loc_of_location binding.vb_expr.exp_loc }

let raw_alias_binding_of_declaration (type_decl : type_declaration) =
  match (type_decl.typ_kind, type_decl.typ_manifest) with
  | Ttype_abstract, Some manifest ->
      Some
        ( type_decl.typ_name.txt,
          parse_type_params type_decl.typ_params,
          parse_type_expr_raw ~current_type:type_decl.typ_name.txt manifest )
  | _ -> None

let type_env_add_alias_binding env (name, params, rhs) =
  type_env_add_alias env name params rhs

let decl_alias_binding = function
  | Type_alias_decl decl ->
      Some (decl.alias_type_name, decl.alias_params, decl.alias_rhs)
  | Tuple_type_decl decl ->
      Some
        ( decl.tuple_type_name,
          decl.tuple_params,
          Type_tuple decl.tuple_items )
  | Let_decl _ | Let_rec_group_decl _ | Type_decl _ | Record_type_decl _
  | External_decl _ ->
      None

let parse_type_declarations env declarations =
  let env_with_group_aliases =
    List.filter_map raw_alias_binding_of_declaration declarations
    |> List.fold_left type_env_add_alias_binding env
  in
  let decls = List.map (parse_type_declaration env_with_group_aliases) declarations in
  let type_decls =
    List.filter_map
      (function Type_decl type_decl -> Some type_decl | _ -> None)
      decls
  in
  let env_with_type_decls = type_env_add_type_decls env type_decls in
  let env_with_aliases =
    List.filter_map decl_alias_binding decls
    |> List.fold_left type_env_add_alias_binding env_with_type_decls
  in
  (env_with_aliases, decls)

let parse_structure_item env (item : structure_item) =
  match item.str_desc with
  | Tstr_value (Nonrecursive, [ binding ]) ->
      (env, [ parse_value_binding env binding ])
  | Tstr_value (Recursive, [ binding ]) ->
      let decl =
        match parse_value_binding env binding with
        | Let_decl decl -> Let_decl { decl with is_rec = true }
        | Let_rec_group_decl _ | Type_decl _ | Tuple_type_decl _ | Record_type_decl _
        | Type_alias_decl _ | External_decl _ ->
            assert false
      in
      (env, [ decl ])
  | Tstr_value (Recursive, (_ :: _ :: _ as bindings)) ->
      (env, [ Let_rec_group_decl (List.map (parse_let_rec_binding env) bindings) ])
  | Tstr_type (_, declarations) ->
      parse_type_declarations env declarations
  | Tstr_primitive value -> (env, [ parse_external_decl value ])
  | Tstr_value (_, []) ->
      unsupported ~node_kind:"Tstr_value(empty)" ~loc:item.str_loc ()
  | Tstr_value (Nonrecursive, _ :: _ :: _) ->
      unsupported ~node_kind:"Tstr_value(and)" ~loc:item.str_loc ()
  | Tstr_open od -> (
      (* ADR-016: skip only a top-level `open` of a module the frontend
         driver resolved to a user file in this closure; the joined
         namespace makes it a no-op. Every other open keeps today's
         E0091 rejection. *)
      match od.open_expr.mod_desc with
      | Tmod_ident (_, { txt = Longident.Lident name; _ })
        when StringSet.mem name env.user_modules ->
          (env, [])
      | _ -> unsupported ~node_kind:"Tstr_open" ~loc:item.str_loc ())
  | other ->
      unsupported ~node_kind:(structure_item_kind other) ~loc:item.str_loc ()

let decl_top_level_names = function
  | Let_decl { name; loc; _ } -> [ (name, Some loc) ]
  | Let_rec_group_decl bindings ->
      List.map (fun binding -> (binding.rec_name, Some binding.rec_loc)) bindings
  | Type_decl { type_name; variants; _ } ->
      (type_name, None)
      :: List.map (fun variant -> (variant.constr_name, None)) variants
  | Tuple_type_decl { tuple_type_name; _ } -> [ (tuple_type_name, None) ]
  | Record_type_decl { record_type_name; _ } -> [ (record_type_name, None) ]
  | Type_alias_decl { alias_type_name; _ } -> [ (alias_type_name, None) ]
  | External_decl { external_name; _ } -> [ (external_name, None) ]

let duplicate_top_level ~file ~prior_file ~name ~loc =
  let fallback = { file; line = 1; col = 0; end_line = 1; end_col = 0 } in
  raise
    (Unsupported
       {
         severity = "error";
         code = "E0102";
         node_kind = "Tstr_value";
         loc = Option.value loc ~default:fallback;
         message =
           Printf.sprintf "duplicate top-level name `%s`: already defined in %s"
             name prior_file;
         hint =
           Some
             "ADR-016 joins the file closure into one flat namespace; rename \
              one of the bindings";
       })

let check_cross_file_duplicates seen ~file decls =
  List.iter
    (fun decl ->
      List.iter
        (fun (name, loc) ->
          if String.equal name "_" then ()
          else
            match Hashtbl.find_opt seen name with
            | Some prior_file when not (String.equal prior_file file) ->
                duplicate_top_level ~file ~prior_file ~name ~loc
            | Some _ -> ()
            | None -> Hashtbl.add seen name file)
        (decl_top_level_names decl))
    decls

let of_structures ~user_modules (structures : (string * structure) list) =
  let user_modules = StringSet.of_list user_modules in
  let seen : (string, string) Hashtbl.t = Hashtbl.create 64 in
  let env0 = { initial_type_env with user_modules } in
  let _env, rev_decls =
    List.fold_left
      (fun acc_state (file, structure) ->
        List.fold_left
          (fun (env, acc) item ->
            let env, item_decls = parse_structure_item env item in
            check_cross_file_duplicates seen ~file item_decls;
            (env, List.rev_append item_decls acc))
          acc_state structure.str_items)
      (env0, []) structures
  in
  Module (List.rev rev_decls |> add_builtin_external_decls |> add_builtin_record_decls)

let of_structure (structure : structure) =
  of_structures ~user_modules:[] [ ("", structure) ]
