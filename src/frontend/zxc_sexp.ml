(* S-expression serializer for the ZxCaml OCaml frontend wire format.

   The serializer is intentionally hand-written to avoid any dependency beyond
   compiler-libs.common.  Version 0.7 contains top-level let declarations,
   whitelisted option/result constructor expressions, basic match expressions,
   user-authored ADT type declarations, nested constructor patterns, guarded
   match arms, tuple/record construction/projection forms, and the P3
   account/syscall/CPI surface, and P5 external declarations. *)
open Format
open Zxc_subset

let version = "1.0"

let is_atom_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' | '\'' | '.' -> true
  | _ -> false

let pp_atom ppf atom =
  if atom <> "" && String.for_all is_atom_char atom then fprintf ppf "%s" atom
  else fprintf ppf "%S" atom

let pp_param ppf = function
  | Anonymous -> fprintf ppf "_"
  | Param name -> pp_atom ppf name

let rec pp_expr ppf = function
  | Const_int n -> fprintf ppf "(const-int %d)" n
  | Const_string value -> fprintf ppf "(const-string %S)" value
  | Var name -> fprintf ppf "(var %a)" pp_atom name
  | Lambda lambda ->
      fprintf ppf "(lambda (";
      pp_params ppf lambda.params;
      fprintf ppf ") %a)" pp_expr lambda.body
  | App app ->
      fprintf ppf "(app %a" pp_expr app.callee;
      List.iter (fun arg -> fprintf ppf " %a" pp_expr arg) app.args;
      fprintf ppf ")"
  | Let let_expr ->
      fprintf ppf "(%s %a %a %a)"
        (if let_expr.is_rec then "let-rec" else "let")
        pp_atom let_expr.name pp_expr let_expr.value
        pp_expr let_expr.body
  | If if_expr ->
      fprintf ppf "(if %a %a %a)" pp_expr if_expr.cond pp_expr
        if_expr.then_branch pp_expr if_expr.else_branch
  | Prim prim ->
      fprintf ppf "(prim %a" pp_atom prim.op;
      List.iter (fun arg -> fprintf ppf " %a" pp_expr arg) prim.args;
      fprintf ppf ")"
  | Ctor ctor ->
      fprintf ppf "(ctor %a" pp_atom ctor.name;
      List.iter (fun arg -> fprintf ppf " %a" pp_expr arg) ctor.args;
      fprintf ppf ")"
  | Tuple items ->
      fprintf ppf "(tuple (items";
      List.iter (fun item -> fprintf ppf " %a" pp_expr item) items;
      fprintf ppf "))"
  | Tuple_project tuple_project ->
      fprintf ppf "(tuple_project %a (index %d))" pp_expr
        tuple_project.tuple_expr tuple_project.index
  | Record record ->
      fprintf ppf "(record (fields (";
      pp_record_expr_fields ppf record.fields;
      fprintf ppf ")))"
  | Field_access field_access ->
      fprintf ppf "(field_access %a %a)" pp_expr field_access.record_expr pp_atom
        field_access.field_name
  | Record_update record_update ->
      fprintf ppf "(record_update %a (fields (" pp_expr record_update.base_expr;
      pp_record_expr_fields ppf record_update.fields;
      fprintf ppf ")))"
  | Match match_expr ->
      fprintf ppf "(match %a" pp_expr match_expr.scrutinee;
      List.iter (fun arm -> fprintf ppf " %a" pp_match_arm arm) match_expr.arms;
      fprintf ppf ")"

and pp_record_expr_fields ppf = function
  | [] -> ()
  | [ field ] -> pp_record_expr_field ppf field
  | field :: rest ->
      pp_record_expr_field ppf field;
      List.iter (fun field -> fprintf ppf " %a" pp_record_expr_field field) rest

and pp_record_expr_field ppf field =
  fprintf ppf "(%a %a)" pp_atom field.field_name pp_expr field.field_value

and pp_params ppf = function
  | [] -> ()
  | [ param ] -> pp_param ppf param
  | param :: rest ->
      fprintf ppf "%a" pp_param param;
      List.iter (fun param -> fprintf ppf " %a" pp_param param) rest

and pp_match_arm ppf arm =
  match arm.guard with
  | None -> fprintf ppf "(case %a %a)" pp_match_pattern arm.pattern pp_expr arm.body
  | Some guard ->
      fprintf ppf "(case %a (when_guard %a %a))" pp_match_pattern arm.pattern
        pp_expr guard pp_expr arm.body

and pp_match_pattern ppf = function
  | Pat_any -> fprintf ppf "_"
  | Pat_var name -> fprintf ppf "(var %a)" pp_atom name
  | Pat_ctor ctor ->
      fprintf ppf "(ctor %a" pp_atom ctor.name;
      List.iter (fun arg -> fprintf ppf " %a" pp_match_pattern arg) ctor.args;
      fprintf ppf ")"
  | Pat_tuple items ->
      fprintf ppf "(tuple_pattern";
      List.iter (fun item -> fprintf ppf " %a" pp_match_pattern item) items;
      fprintf ppf ")"
  | Pat_record fields ->
      fprintf ppf "(record_pattern (fields (";
      pp_record_pattern_fields ppf fields;
      fprintf ppf ")))"

and pp_record_pattern_fields ppf = function
  | [] -> ()
  | [ field ] -> pp_record_pattern_field ppf field
  | field :: rest ->
      pp_record_pattern_field ppf field;
      List.iter (fun field -> fprintf ppf " %a" pp_record_pattern_field field) rest

and pp_record_pattern_field ppf field =
  fprintf ppf "(%a %a)" pp_atom field.pattern_field_name pp_match_pattern
    field.pattern_field_value

let rec pp_decl ppf decl =
  match decl with
  | Let_decl decl ->
      fprintf ppf "(%s %a %a)"
        (if decl.is_rec then "let-rec" else "let")
        pp_atom decl.name pp_expr decl.body
  | Type_decl decl ->
      fprintf ppf "(type_decl (name %a)" pp_atom decl.type_name;
      fprintf ppf " (params";
      List.iter (fun param -> fprintf ppf " %a" pp_atom param) decl.params;
      fprintf ppf ")";
      if decl.is_recursive then fprintf ppf " (recursive true)";
      fprintf ppf " (variants (";
      pp_type_variants ppf decl.variants;
      fprintf ppf ")))"
  | Tuple_type_decl decl ->
      fprintf ppf "(tuple_type_decl (name %a)" pp_atom decl.tuple_type_name;
      fprintf ppf " (params";
      List.iter (fun param -> fprintf ppf " %a" pp_atom param) decl.tuple_params;
      fprintf ppf ")";
      if decl.tuple_is_recursive then fprintf ppf " (recursive true)";
      fprintf ppf " (items";
      List.iter (fun ty -> fprintf ppf " %a" pp_type_expr ty) decl.tuple_items;
      fprintf ppf "))"
  | Record_type_decl decl ->
      fprintf ppf "(record_type_decl (name %a)" pp_atom decl.record_type_name;
      fprintf ppf " (params";
      List.iter (fun param -> fprintf ppf " %a" pp_atom param) decl.record_params;
      fprintf ppf ")";
      if decl.record_is_recursive then fprintf ppf " (recursive true)";
      fprintf ppf " (fields (";
      pp_record_type_fields ppf decl.record_fields;
      fprintf ppf "))";
      if decl.record_is_account then fprintf ppf " (account_attr)";
      fprintf ppf ")"
  | External_decl decl ->
      fprintf ppf "(external (name %S) (type %a) (symbol %S))"
        decl.external_name pp_external_type_expr decl.external_type
        decl.external_symbol

and pp_type_variants ppf = function
  | [] -> ()
  | [ variant ] -> pp_type_variant ppf variant
  | variant :: rest ->
      pp_type_variant ppf variant;
      List.iter (fun variant -> fprintf ppf " %a" pp_type_variant variant) rest

and pp_type_variant ppf variant =
  fprintf ppf "(%a (payload_types" pp_atom variant.constr_name;
  List.iter (fun ty -> fprintf ppf " %a" pp_type_expr ty) variant.payload_types;
  fprintf ppf "))"

and pp_record_type_fields ppf = function
  | [] -> ()
  | [ field ] -> pp_record_type_field ppf field
  | field :: rest ->
      pp_record_type_field ppf field;
      List.iter (fun field -> fprintf ppf " %a" pp_record_type_field field) rest

and pp_record_type_field ppf field =
  fprintf ppf "(%a %a" pp_atom field.record_field_name pp_type_expr
    field.record_field_type;
  if field.record_field_mutable then fprintf ppf " (mutable true)";
  fprintf ppf ")"

and pp_type_expr ppf = function
  | Type_var name -> fprintf ppf "(type-var %a)" pp_atom name
  | Type_tuple items ->
      fprintf ppf "(tuple-type";
      List.iter (fun item -> fprintf ppf " %a" pp_type_expr item) items;
      fprintf ppf ")"
  | Type_constr constr ->
      fprintf ppf "(%s %a"
        (if constr.is_recursive_ref then "recursive-ref" else "type-ref")
        pp_atom constr.type_name;
      List.iter (fun arg -> fprintf ppf " %a" pp_type_expr arg) constr.args;
      fprintf ppf ")"

and pp_external_type_expr ppf = function
  | External_type_constr { external_type_name; external_type_args = [] } ->
      pp_atom ppf external_type_name
  | External_type_constr { external_type_name; external_type_args } ->
      fprintf ppf "(type-ref %a" pp_atom external_type_name;
      List.iter
        (fun arg -> fprintf ppf " %a" pp_external_type_expr arg)
        external_type_args;
      fprintf ppf ")"
  | External_type_tuple items ->
      fprintf ppf "(tuple";
      List.iter (fun item -> fprintf ppf " %a" pp_external_type_expr item) items;
      fprintf ppf ")"
  | External_type_arrow (arg, result) ->
      fprintf ppf "(arrow %a %a)" pp_external_type_expr arg
        pp_external_type_expr result

let pp_module ppf = function
  | Module decls ->
      fprintf ppf "(zxcaml-cir %s (module" version;
      List.iter (fun decl -> fprintf ppf " %a" pp_decl decl) decls;
      fprintf ppf "))"

let to_string modul = asprintf "%a@." pp_module modul
