(* Command-line entrypoint for the OCaml side of the ZxCaml frontend.

   `zxc-frontend --emit=sexp file.ml` drives upstream `ocamlc -bin-annot`,
   loads the resulting .cmt with compiler-libs, checks the M0 Typedtree subset,
   and writes the versioned ZxCaml S-expression to stdout. *)

let json_escape s =
  let buffer = Buffer.create (String.length s + 16) in
  String.iter
    (function
      | '"' -> Buffer.add_string buffer "\\\""
      | '\\' -> Buffer.add_string buffer "\\\\"
      | '\b' -> Buffer.add_string buffer "\\b"
      | '\012' -> Buffer.add_string buffer "\\f"
      | '\n' -> Buffer.add_string buffer "\\n"
      | '\r' -> Buffer.add_string buffer "\\r"
      | '\t' -> Buffer.add_string buffer "\\t"
      | c ->
          let code = Char.code c in
          if code < 0x20 then Buffer.add_string buffer (Printf.sprintf "\\u%04x" code)
          else Buffer.add_char buffer c)
    s;
  Buffer.contents buffer

let pp_json_string ppf value = Format.fprintf ppf "\"%s\"" (json_escape value)

let emit_diagnostic (diagnostic : Zxc_subset.diagnostic) =
  let loc = diagnostic.loc in
  Format.eprintf
    "@[<h>{\"severity\":%a,\"code\":%a,\"message\":%a,\"node_kind\":%a,\
     \"loc\":{\"file\":%a,\"line\":%d,\"col\":%d,\"end_line\":%d,\
     \"end_col\":%d}}@]@."
    pp_json_string diagnostic.severity pp_json_string diagnostic.code pp_json_string
    diagnostic.message pp_json_string diagnostic.node_kind pp_json_string loc.file
    loc.line loc.col loc.end_line loc.end_col

let emit_internal_error ~message =
  let diagnostic : Zxc_subset.diagnostic =
    {
      severity = "error";
      code = "M0-INTERNAL";
      node_kind = "internal";
      loc =
        {
          file = "_unknown_";
          line = 1;
          col = 0;
          end_line = 1;
          end_col = 0;
        };
      message;
    }
  in
  emit_diagnostic diagnostic

let usage () =
  prerr_endline "usage: zxc-frontend --emit=sexp <input.ml>";
  exit 3

let parse_args () =
  match Array.to_list Sys.argv with
  | [ _program; "--emit=sexp"; input ] -> input
  | _ -> usage ()

let cmt_modname_to_string (info : Cmt_format.cmt_infos) =
  (info.cmt_modname :> string)

let ocamlc_command () =
  match Sys.command "command -v ocamlc >/dev/null 2>&1" with
  | 0 -> "ocamlc"
  | _ -> "opam exec --switch=zxcaml-p1 -- ocamlc"

let compile_to_cmt input =
  let tmp_cmo = Filename.temp_file "Zxcaml_" ".cmo" in
  let tmp_prefix = Filename.remove_extension tmp_cmo in
  let tmp_cmt = tmp_prefix ^ ".cmt" in
  let command =
    Printf.sprintf "%s -bin-annot -c %s -o %s" (ocamlc_command ())
      (Filename.quote input) (Filename.quote tmp_cmo)
  in
  match Sys.command command with
  | 0 -> (tmp_cmo, tmp_cmt)
  | status ->
      emit_internal_error
        ~message:
          (Printf.sprintf "ocamlc -bin-annot failed for %s with status %d" input
             status);
      exit 2

let cleanup paths =
  List.iter
    (fun path -> try Sys.remove path with Sys_error _ -> ())
    paths

let load_implementation cmt_path =
  let info = Cmt_format.read_cmt cmt_path in
  let (_module_name : string) = cmt_modname_to_string info in
  match info.cmt_annots with
  | Implementation structure -> structure
  | Interface _ | Packed _ | Partial_implementation _ | Partial_interface _ ->
      emit_internal_error
        ~message:(Printf.sprintf "expected an implementation .cmt: %s" cmt_path);
      exit 3

let () =
  let input = parse_args () in
  let tmp_cmo, tmp_cmt = compile_to_cmt input in
  let tmp_cmi = Filename.remove_extension tmp_cmo ^ ".cmi" in
  try
    let structure = load_implementation tmp_cmt in
    let modul = Zxc_subset.of_structure structure in
    print_string (Zxc_sexp.to_string modul);
    cleanup [ tmp_cmo; tmp_cmt; tmp_cmi ]
  with
  | Zxc_subset.Unsupported diagnostic ->
      emit_diagnostic diagnostic;
      cleanup [ tmp_cmo; tmp_cmt; tmp_cmi ];
      exit 1
  | Cmt_format.Error error ->
      let message =
        match error with
        | Cmt_format.Not_a_typedtree path ->
            Printf.sprintf "not a typedtree file: %s" path
      in
      emit_internal_error
        ~message;
      cleanup [ tmp_cmo; tmp_cmt; tmp_cmi ];
      exit 3
  | Sys_error message ->
      emit_internal_error ~message;
      cleanup [ tmp_cmo; tmp_cmt; tmp_cmi ];
      exit 3
