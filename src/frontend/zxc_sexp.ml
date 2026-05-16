(* S-expression serializer for the ZxCaml OCaml frontend wire format.

   The serializer is intentionally hand-written to avoid any dependency beyond
   compiler-libs.common.  Version 0.7 contains top-level let declarations,
   whitelisted option/result constructor expressions, basic match expressions,
   user-authored ADT type declarations, nested constructor patterns, guarded
   match arms, tuple/record construction/projection forms, and the P3
   account/syscall/CPI surface, P5 external declarations, and P9 mutual
   recursive binding groups and assert expressions. *)
open Format
open Zxc_subset

type wire_version = Wire_1_1 | Wire_1_2 | Wire_1_3 | Wire_1_4 | Wire_1_5

let version = function
  | Wire_1_1 -> "1.1"
  | Wire_1_2 -> "1.2"
  | Wire_1_3 -> "1.3"
  | Wire_1_4 -> "1.4"
  | Wire_1_5 -> "1.5"

let wire_version_of_string = function
  | "1.1" -> Some Wire_1_1
  | "1.2" -> Some Wire_1_2
  | "1.3" -> Some Wire_1_3
  | "1.4" -> Some Wire_1_4
  | "1.5" -> Some Wire_1_5
  | _ -> None

let emit_param_types = function
  | Wire_1_1 | Wire_1_2 -> false
  | Wire_1_3 | Wire_1_4 | Wire_1_5 -> true

let is_atom_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' | '\'' | '.' -> true
  | _ -> false

let pp_atom ppf atom =
  if atom <> "" && String.for_all is_atom_char atom then fprintf ppf "%s" atom
  else fprintf ppf "%S" atom

let pp_param ppf = function
  | Anonymous -> fprintf ppf "_"
  | Param name -> pp_atom ppf name

let pp_loc ppf (loc : loc) =
  fprintf ppf "(loc %S %d %d %d %d)" loc.file loc.line loc.col loc.end_line
    loc.end_col

let rec pp_type_expr ppf = function
  | Type_var name -> fprintf ppf "(type-var %a)" pp_atom name
  | Type_any -> fprintf ppf "(any)"
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

let rec pp_expr ~wire ppf = function
  | Const_int n -> fprintf ppf "(const-int %d)" n
  | Const_string value -> fprintf ppf "(const-string %S)" value
  | Var name -> fprintf ppf "(var %a)" pp_atom name
  | Lambda lambda ->
      fprintf ppf "(lambda (";
      pp_lambda_params ~wire ppf lambda.params lambda.param_types;
      fprintf ppf ") %a)" (pp_expr ~wire) lambda.body
  | App app ->
      fprintf ppf "(app %a" (pp_expr ~wire) app.callee;
      List.iter (fun arg -> fprintf ppf " %a" (pp_expr ~wire) arg) app.args;
      fprintf ppf ")"
  | Let let_expr ->
      fprintf ppf "(%s %a %a %a)"
        (if let_expr.is_rec then "let-rec" else "let")
        pp_atom let_expr.name (pp_expr ~wire) let_expr.value
        (pp_expr ~wire) let_expr.body
  | Let_rec_group group ->
      fprintf ppf "(Let_rec_group (bindings";
      List.iter
        (fun binding -> fprintf ppf " %a" (pp_let_rec_binding ~wire) binding)
        group.bindings;
      fprintf ppf ") %a)" (pp_expr ~wire) group.group_body
  | If if_expr ->
      fprintf ppf "(if %a %a %a)" (pp_expr ~wire) if_expr.cond (pp_expr ~wire)
        if_expr.then_branch (pp_expr ~wire) if_expr.else_branch
  | Prim prim ->
      fprintf ppf "(prim %a" pp_atom prim.op;
      List.iter (fun arg -> fprintf ppf " %a" (pp_expr ~wire) arg) prim.args;
      fprintf ppf ")"
  | Ctor ctor ->
      fprintf ppf "(ctor %a" pp_atom ctor.name;
      List.iter (fun arg -> fprintf ppf " %a" (pp_expr ~wire) arg) ctor.args;
      fprintf ppf ")"
  | Tuple items ->
      fprintf ppf "(tuple (items";
      List.iter (fun item -> fprintf ppf " %a" (pp_expr ~wire) item) items;
      fprintf ppf "))"
  | Tuple_project tuple_project ->
      fprintf ppf "(tuple_project %a (index %d))" (pp_expr ~wire)
        tuple_project.tuple_expr tuple_project.index
  | Record record ->
      fprintf ppf "(record (fields (";
      pp_record_expr_fields ~wire ppf record.fields;
      fprintf ppf ")))"
  | Field_access field_access ->
      fprintf ppf "(field_access %a %a)" (pp_expr ~wire) field_access.record_expr pp_atom
        field_access.field_name
  | Field_set field_set ->
      fprintf ppf "(field_set %a %a %a)" (pp_expr ~wire) field_set.record_expr pp_atom
        field_set.field_name (pp_expr ~wire) field_set.value
  | Record_update record_update ->
      fprintf ppf "(record_update %a (fields (" (pp_expr ~wire) record_update.base_expr;
      pp_record_expr_fields ~wire ppf record_update.fields;
      fprintf ppf ")))"
  | Assert condition -> fprintf ppf "(Assert %a)" (pp_expr ~wire) condition
  | Match match_expr ->
      fprintf ppf "(match %a" (pp_expr ~wire) match_expr.scrutinee;
      List.iter (fun arm -> fprintf ppf " %a" (pp_match_arm ~wire) arm) match_expr.arms;
      fprintf ppf ")"
  | Array_lit elems ->
      (* ADR-015 option B / R9.1: int array literal. Element type is pinned
         to (type-ref int) on the wire; downstream layers reject non-int
         element types with E0040 before reaching this emitter. *)
      fprintf ppf "(array-lit (ty (type-ref int))";
      List.iter (fun elem -> fprintf ppf " %a" (pp_expr ~wire) elem) elems;
      fprintf ppf ")"
  | Array_get { array_expr; index_expr } ->
      fprintf ppf "(array-get %a %a)" (pp_expr ~wire) array_expr (pp_expr ~wire) index_expr
  | Array_length array_expr ->
      fprintf ppf "(array-length %a)" (pp_expr ~wire) array_expr
  | Array_set { set_array_expr; set_index_expr; set_value_expr } ->
      (* ADR-015 option B / R9.2: in-place int array write. *)
      fprintf ppf "(array-set %a %a %a)" (pp_expr ~wire) set_array_expr
        (pp_expr ~wire) set_index_expr (pp_expr ~wire) set_value_expr
  | Array_make { make_size; make_init } ->
      (* ADR-015 option B / R9.2: literal-size int array make. *)
      fprintf ppf "(array-make %d %a (ty (type-ref int)))" make_size
        (pp_expr ~wire) make_init
  | Ref_make { ref_elem_ty; ref_init } ->
      (* ADR-015 option C / R10: 1-slot arena-allocated ref cell. The
         element type is baked into the sexp envelope and restricted to the
         R10 whitelist (int / bool / option<int|bool>). *)
      fprintf ppf "(ref-make (ty %a) %a)" pp_type_expr ref_elem_ty
        (pp_expr ~wire) ref_init
  | Ref_get target -> fprintf ppf "(ref-get %a)" (pp_expr ~wire) target
  | Ref_set { ref_set_target; ref_set_value } ->
      fprintf ppf "(ref-set %a %a)" (pp_expr ~wire) ref_set_target
        (pp_expr ~wire) ref_set_value

and pp_expr_with_loc ~wire ppf (loc, expr) =
  fprintf ppf "(located %a %a)" pp_loc loc (pp_expr ~wire) expr

and pp_record_expr_fields ~wire ppf = function
  | [] -> ()
  | [ field ] -> pp_record_expr_field ~wire ppf field
  | field :: rest ->
      pp_record_expr_field ~wire ppf field;
      List.iter (fun field -> fprintf ppf " %a" (pp_record_expr_field ~wire) field) rest

and pp_record_expr_field ~wire ppf field =
  fprintf ppf "(%a %a)" pp_atom field.field_name (pp_expr ~wire) field.field_value

and pp_let_rec_binding ~wire ppf binding =
  fprintf ppf "(binding (name %a) (params" pp_atom binding.rec_name;
  pp_rec_params ~wire ppf binding.rec_params binding.rec_param_types;
  fprintf ppf ") (body %a))" (pp_expr ~wire) binding.rec_body

and pp_let_rec_binding_with_loc ~wire ppf binding =
  fprintf ppf "(binding (name %a) (params" pp_atom binding.rec_name;
  pp_rec_params ~wire ppf binding.rec_params binding.rec_param_types;
  fprintf ppf ") (body %a))" (pp_expr_with_loc ~wire) (binding.rec_loc, binding.rec_body)

and pp_lambda_params ~wire ppf params param_types =
  if emit_param_types wire then
    pp_typed_lambda_params ppf params param_types
  else
    pp_params ppf params

and pp_typed_lambda_params ppf params param_types =
  let typed_list =
    let rec zip ps ts =
      match (ps, ts) with
      | [], _ -> []
      | p :: prest, [] -> (p, None) :: zip prest []
      | p :: prest, t :: trest -> (p, t) :: zip prest trest
    in
    zip params param_types
  in
  let pp_one ppf (param, ty_opt) =
    let ty = match ty_opt with Some ty -> ty | None -> Type_any in
    fprintf ppf "(%a (ty %a))" pp_param param pp_type_expr ty
  in
  match typed_list with
  | [] -> ()
  | [ one ] -> pp_one ppf one
  | first :: rest ->
      pp_one ppf first;
      List.iter (fun pair -> fprintf ppf " %a" pp_one pair) rest

and pp_rec_params ~wire ppf params param_types =
  if emit_param_types wire then begin
    let pad_types =
      let rec pad ps ts =
        match (ps, ts) with
        | [], _ -> []
        | _ :: prest, [] -> None :: pad prest []
        | _ :: prest, t :: trest -> t :: pad prest trest
      in
      pad params param_types
    in
    List.iter2
      (fun param ty_opt ->
        let ty = match ty_opt with Some ty -> ty | None -> Type_any in
        fprintf ppf " (%a (ty %a))" pp_param param pp_type_expr ty)
      params pad_types
  end else
    List.iter (fun param -> fprintf ppf " %a" pp_param param) params

and pp_params ppf = function
  | [] -> ()
  | [ param ] -> pp_param ppf param
  | param :: rest ->
      fprintf ppf "%a" pp_param param;
      List.iter (fun param -> fprintf ppf " %a" pp_param param) rest

and pp_match_arm ~wire ppf arm =
  match arm.guard with
  | None ->
      fprintf ppf "(case %a %a)" pp_match_pattern arm.pattern (pp_expr ~wire) arm.body
  | Some guard ->
      fprintf ppf "(case %a (when_guard %a %a))" pp_match_pattern arm.pattern
        (pp_expr ~wire) guard (pp_expr ~wire) arm.body

and pp_match_pattern ppf = function
  | Pat_any -> fprintf ppf "_"
  | Pat_var name -> fprintf ppf "(var %a)" pp_atom name
  | Pat_const const -> fprintf ppf "(const-pattern %a)" pp_const_pattern const
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
  | Pat_or alternatives ->
      fprintf ppf "(or-pattern";
      List.iter
        (fun alternative -> fprintf ppf " %a" pp_match_pattern alternative)
        alternatives;
      fprintf ppf ")"
  | Pat_alias alias ->
      fprintf ppf "(alias-pattern %a %a)" pp_match_pattern alias.alias_pattern
        pp_atom alias.alias_name

and pp_const_pattern ppf = function
  | Const_pat_int n -> fprintf ppf "(const-int %d)" n
  | Const_pat_string value -> fprintf ppf "(const-string %S)" value
  | Const_pat_char value -> fprintf ppf "(const-char %d)" (Char.code value)

and pp_record_pattern_fields ppf = function
  | [] -> ()
  | [ field ] -> pp_record_pattern_field ppf field
  | field :: rest ->
      pp_record_pattern_field ppf field;
      List.iter (fun field -> fprintf ppf " %a" pp_record_pattern_field field) rest

and pp_record_pattern_field ppf field =
  fprintf ppf "(%a %a)" pp_atom field.pattern_field_name pp_match_pattern
    field.pattern_field_value

let rec pp_decl ~wire ppf decl =
  let emit_locs =
    match wire with Wire_1_2 | Wire_1_3 | Wire_1_4 | Wire_1_5 -> true | Wire_1_1 -> false
  in
  match decl with
  | Let_decl decl ->
      fprintf ppf "(%s %a %a)"
        (if decl.is_rec then "let-rec" else "let")
        pp_atom decl.name
        (if emit_locs then pp_expr_with_loc ~wire
         else fun ppf (_, expr) -> pp_expr ~wire ppf expr)
        (decl.loc, decl.body)
  | Let_rec_group_decl bindings ->
      fprintf ppf "(Let_rec_group (bindings";
      List.iter
        (fun binding ->
          fprintf ppf " %a"
            (if emit_locs then pp_let_rec_binding_with_loc ~wire
             else pp_let_rec_binding ~wire)
            binding)
        bindings;
      fprintf ppf "))"
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
  | Type_alias_decl decl ->
      fprintf ppf "(type_alias_decl (name %a)" pp_atom decl.alias_type_name;
      fprintf ppf " (params";
      List.iter (fun param -> fprintf ppf " %a" pp_atom param) decl.alias_params;
      fprintf ppf ") (rhs %a))" pp_type_expr decl.alias_rhs
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

let pp_module ~wire ppf = function
  | Module decls ->
      fprintf ppf "(zxcaml-cir %s (module" (version wire);
      List.iter (fun decl -> fprintf ppf " %a" (pp_decl ~wire) decl) decls;
      fprintf ppf "))"

let to_string ?(wire = Wire_1_5) modul = asprintf "%a@." (pp_module ~wire) modul
