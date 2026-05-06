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
  let pp_optional_field ppf = function
    | None -> ()
    | Some value -> Format.fprintf ppf ",\"hint\":%a" pp_json_string value
  in
  Format.eprintf
    "@[<h>{\"file\":%a,\"line\":%d,\"col\":%d,\"end_line\":%d,\"end_col\":%d,\
     \"severity\":%a,\"code\":%a,\"message\":%a,\"node_kind\":%a%a}@]@."
    pp_json_string loc.file loc.line loc.col loc.end_line loc.end_col
    pp_json_string diagnostic.severity pp_json_string diagnostic.code
    pp_json_string diagnostic.message pp_json_string diagnostic.node_kind pp_optional_field
    diagnostic.hint

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
      hint = None;
    }
  in
  emit_diagnostic diagnostic

let starts_with ~prefix s =
  let prefix_len = String.length prefix in
  String.length s >= prefix_len && String.sub s 0 prefix_len = prefix

let find_line predicate text =
  let lines = String.split_on_char '\n' text in
  List.find_opt predicate lines

let parse_int_span_at s start =
  let len = String.length s in
  let rec advance index =
    if index < len then
      match s.[index] with '0' .. '9' -> advance (index + 1) | _ -> index
    else index
  in
  let finish = advance start in
  if finish = start then None
  else
    Option.map
      (fun value -> (value, finish))
      (int_of_string_opt (String.sub s start (finish - start)))

let parse_int_at s start = Option.map fst (parse_int_span_at s start)

let find_sub_from s sub start =
  let s_len = String.length s in
  let sub_len = String.length sub in
  let rec loop index =
    if index + sub_len > s_len then None
    else if String.sub s index sub_len = sub then Some index
    else loop (index + 1)
  in
  loop start

let parse_ocamlc_location ~input stderr =
  match find_line (starts_with ~prefix:"File \"") stderr with
  | None -> { Zxc_subset.file = input; line = 1; col = 0; end_line = 1; end_col = 0 }
  | Some line -> (
      try
        let file_start = String.length "File \"" in
        let file_end = String.index_from line file_start '"' in
        let file = String.sub line file_start (file_end - file_start) in
        let line_prefix = ", line " in
        let chars_prefix = ", characters " in
        let line_number =
          match find_sub_from line line_prefix file_end with
          | Some index -> parse_int_at line (index + String.length line_prefix)
          | None -> None
        in
        let col, end_col =
          match find_sub_from line chars_prefix file_end with
          | Some index -> (
              let chars_start = index + String.length chars_prefix in
              match parse_int_span_at line chars_start with
              | Some (start_col, after_start) ->
                  let parsed_end_col =
                    if after_start < String.length line && line.[after_start] = '-' then
                      parse_int_at line (after_start + 1)
                    else None
                  in
                  (Some start_col, parsed_end_col)
              | None -> (None, None))
          | None -> (None, None)
        in
        let line_number = Option.value line_number ~default:1 in
        let col = Option.value col ~default:0 in
        let end_col = Option.value end_col ~default:col in
        { Zxc_subset.file; line = line_number; col; end_line = line_number; end_col }
      with Invalid_argument _ | Not_found ->
        { Zxc_subset.file = input; line = 1; col = 0; end_line = 1; end_col = 0 })

let parse_ocamlc_message stderr =
  let lines = String.split_on_char '\n' stderr in
  let is_blank line = String.trim line = "" in
  let is_indented line =
    String.length line > 0
    &&
    match line.[0] with
    | ' ' | '\t' -> true
    | _ -> false
  in
  let remove_error_prefix line =
    let trimmed = String.trim line in
    String.trim
      (String.sub trimmed (String.length "Error:")
         (String.length trimmed - String.length "Error:"))
  in
  let rec collect_continuations acc = function
    | line :: rest when is_blank line -> List.rev acc
    | line :: rest when is_indented line ->
        collect_continuations (String.trim line :: acc) rest
    | _ -> List.rev acc
  in
  let rec find_error_block = function
    | [] -> None
    | line :: rest ->
        if starts_with ~prefix:"Error:" (String.trim line) then
          Some (remove_error_prefix line :: collect_continuations [] rest)
        else find_error_block rest
  in
  match find_error_block lines with
  | Some parts ->
      let parts = List.filter (fun part -> part <> "") parts in
      String.concat " " parts
  | None ->
      let trimmed = String.trim stderr in
      if trimmed = "" then "ocamlc -bin-annot failed" else trimmed

let read_file path =
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () ->
      let length = in_channel_length channel in
      really_input_string channel length)

let write_file path contents =
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () -> output_string channel contents)

let emit_ocamlc_error ~input ~stderr =
  let diagnostic : Zxc_subset.diagnostic =
    {
      severity = "error";
      code = "OCAML-FRONTEND";
      node_kind = "ocamlc";
      loc = parse_ocamlc_location ~input stderr;
      message = parse_ocamlc_message stderr;
      hint = None;
    }
  in
  emit_diagnostic diagnostic

let emit_frontend_parse_error ~input ~line ~col ~end_col ~code ~node_kind
    ~message ?hint () =
  let diagnostic : Zxc_subset.diagnostic =
    {
      severity = "error";
      code;
      node_kind;
      loc =
        {
          file = input;
          line;
          col;
          end_line = line;
          end_col = max col end_col;
        };
      message;
      hint;
    }
  in
  emit_diagnostic diagnostic;
  exit 2

let usage () =
  prerr_endline "usage: zxc-frontend --emit=sexp [--wire=1.1|--wire=1.2] <input.ml>";
  exit 3

let parse_args () =
  match Array.to_list Sys.argv with
  | [ _program; "--emit=sexp"; input ] -> (input, Zxc_sexp.Wire_1_2)
  | [ _program; "--emit=sexp"; wire_flag; input ]
    when starts_with ~prefix:"--wire=" wire_flag -> (
      let requested = String.sub wire_flag (String.length "--wire=")
          (String.length wire_flag - String.length "--wire=") in
      match Zxc_sexp.wire_version_of_string requested with
      | Some wire -> (input, wire)
      | None -> usage ())
  | _ -> usage ()

let cmt_modname_to_string (info : Cmt_format.cmt_infos) =
  (info.cmt_modname :> string)

let ocamlc_command () =
  match Sys.command "command -v ocamlc >/dev/null 2>&1" with
  | 0 -> "ocamlc"
  | _ -> "opam exec --switch=zxcaml-p1 -- ocamlc"

let absolute_path path =
  if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path else path

type otest_binding = {
  index : int;
  name_literal : string;
}

let identifier_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '\'' -> true
  | _ -> false

let read_identifier s start =
  let len = String.length s in
  let rec loop index =
    if index < len && identifier_char s.[index] then loop (index + 1) else index
  in
  let finish = loop start in
  String.sub s start (finish - start), finish

let skip_horizontal_space s start =
  let len = String.length s in
  let rec loop index =
    if index < len then
      match s.[index] with ' ' | '\t' -> loop (index + 1) | _ -> index
    else index
  in
  loop start

let parse_string_literal_end s start =
  let len = String.length s in
  if start >= len || s.[start] <> '"' then None
  else
    let rec loop index escaped =
      if index >= len then None
      else if escaped then loop (index + 1) false
      else
        match s.[index] with
        | '\\' -> loop (index + 1) true
        | '"' -> Some (index + 1)
        | _ -> loop (index + 1) false
    in
    loop (start + 1) false

let find_let_percent line = find_sub_from line "let%" 0

let top_level_boundary line =
  starts_with ~prefix:"let " line
  || starts_with ~prefix:"let\t" line
  || starts_with ~prefix:"let%" line
  || starts_with ~prefix:"let rec " line
  || starts_with ~prefix:"type " line
  || starts_with ~prefix:"external " line

let parse_otest_header ~input ~line_number line =
  let ext, after_ext = read_identifier line (String.length "let%") in
  if not (String.equal ext "test_unit") then
    emit_frontend_parse_error ~input ~line:line_number ~col:0 ~end_col:after_ext
      ~code:"OTEST-PARSE" ~node_kind:"let-extension"
      ~message:
        (Printf.sprintf
           "unknown let%% extension `%s`; only let%%test_unit is supported" ext)
      ~hint:"supported syntax: let%test_unit \"name\" = expr" ();
  let after_ext = skip_horizontal_space line after_ext in
  let literal_end =
    match parse_string_literal_end line after_ext with
    | Some finish -> finish
    | None ->
        emit_frontend_parse_error ~input ~line:line_number ~col:after_ext
          ~end_col:(max (after_ext + 1) (String.length line))
          ~code:"OTEST-PARSE" ~node_kind:"let%test_unit"
          ~message:"expected a string literal test name after let%test_unit"
          ~hint:"write: let%test_unit \"descriptive name\" = expr" ()
  in
  let after_literal = skip_horizontal_space line literal_end in
  if after_literal >= String.length line || line.[after_literal] <> '=' then
    emit_frontend_parse_error ~input ~line:line_number ~col:after_literal
      ~end_col:(after_literal + 1)
      ~code:"OTEST-PARSE" ~node_kind:"let%test_unit"
      ~message:"expected `=` after let%test_unit test name"
      ~hint:"write: let%test_unit \"descriptive name\" = expr" ();
  let name_literal = String.sub line after_ext (literal_end - after_ext) in
  let rhs_tail =
    String.sub line (after_literal + 1) (String.length line - after_literal - 1)
  in
  name_literal, rhs_tail

let reject_nested_or_unknown_extension ~input ~line_number line column =
  let ext, after_ext = read_identifier line (column + String.length "let%") in
  if String.equal ext "test_unit" then
    emit_frontend_parse_error ~input ~line:line_number ~col:column
      ~end_col:after_ext ~code:"OTEST-PARSE" ~node_kind:"let%test_unit"
      ~message:"let%test_unit is only supported as a top-level binding"
      ~hint:"move this test to the module top level" ()
  else
    emit_frontend_parse_error ~input ~line:line_number ~col:column
      ~end_col:after_ext ~code:"OTEST-PARSE" ~node_kind:"let-extension"
      ~message:
        (Printf.sprintf
           "unknown let%% extension `%s`; only let%%test_unit is supported" ext)
      ~hint:"supported syntax: let%test_unit \"name\" = expr" ()

let append_otest_registry buffer bindings =
  Buffer.add_string buffer
    "\nlet __otest_registry__ : (string * (unit -> unit)) list =\n";
  Buffer.add_string buffer "  [\n";
  List.iter
    (fun binding ->
      Buffer.add_string buffer
        (Printf.sprintf "    (%s, __otest_unit_%d__);\n" binding.name_literal
           binding.index))
    bindings;
  Buffer.add_string buffer "  ]\n"

let preprocess_otest_source input =
  let source = read_file input in
  let lines = String.split_on_char '\n' source in
  let buffer = Buffer.create (String.length source + 256) in
  let bindings = ref [] in
  let rec loop line_number = function
    | [] -> ()
    | line :: rest ->
        if starts_with ~prefix:"let%" line then (
          let index = List.length !bindings in
          let name_literal, rhs_tail = parse_otest_header ~input ~line_number line in
          bindings := !bindings @ [ { index; name_literal } ];
          Buffer.add_string buffer
            (Printf.sprintf "let __otest_unit_%d__ _ : unit =%s\n" index
               rhs_tail);
          let rec append_body current_line = function
            | next :: remaining when not (top_level_boundary next) ->
                (match find_let_percent next with
                | Some column ->
                    reject_nested_or_unknown_extension ~input
                      ~line_number:current_line next column
                | None -> ());
                Buffer.add_string buffer next;
                Buffer.add_char buffer '\n';
                append_body (current_line + 1) remaining
            | remaining -> loop current_line remaining
          in
          append_body (line_number + 1) rest)
        else (
          (match find_let_percent line with
          | Some column ->
              reject_nested_or_unknown_extension ~input ~line_number line column
          | None -> ());
          Buffer.add_string buffer line;
          (match rest with [] -> () | _ -> Buffer.add_char buffer '\n');
          loop (line_number + 1) rest)
  in
  loop 1 lines;
  if !bindings = [] then None
  else (
    append_otest_registry buffer !bindings;
    let path = Filename.temp_file "Zxcaml_otest_" ".ml" in
    write_file path
      (Printf.sprintf "# 1 %S\n%s" (absolute_path input) (Buffer.contents buffer));
    Some path)

let file_exists path =
  try Sys.file_exists path && not (Sys.is_directory path)
  with Sys_error _ -> false

let first_existing = List.find_opt file_exists

let bundled_stdlib_core_path () =
  let from_env =
    match Sys.getenv_opt "ZXC_STDLIB_CORE" with
    | Some path -> [ path ]
    | None -> []
  in
  let from_cwd = [ Filename.concat (Sys.getcwd ()) "stdlib/core.ml" ] in
  let from_executable =
    let exe = absolute_path Sys.executable_name in
    let bin_dir = Filename.dirname exe in
    let zig_out_dir = Filename.dirname bin_dir in
    let repo_root = Filename.dirname zig_out_dir in
    [ Filename.concat repo_root "stdlib/core.ml" ]
  in
  match first_existing (from_env @ from_cwd @ from_executable) with
  | Some path -> path
  | None ->
      emit_internal_error
        ~message:
          "could not locate bundled stdlib/core.ml; set ZXC_STDLIB_CORE or run \
           zxc-frontend from the repository root";
      exit 3

let make_temp_dir prefix =
  let marker = Filename.temp_file prefix ".dir" in
  Sys.remove marker;
  Sys.mkdir marker 0o700;
  marker

let cleanup_bundled_stdlib_dir dir =
  List.iter
    (fun name ->
      let path = Filename.concat dir name in
      try Sys.remove path with Sys_error _ -> ())
    [ "core.cmi"; "core.cmo"; "core.o"; "core.stderr" ];
  try Sys.rmdir dir with Sys_error _ -> ()

let compile_bundled_stdlib ~dir =
  let core_path = bundled_stdlib_core_path () in
  let stderr_path = Filename.concat dir "core.stderr" in
  let command =
    Printf.sprintf "cd %s && %s -c %s -o core.cmo 2> %s"
      (Filename.quote dir) (ocamlc_command ()) (Filename.quote core_path)
      (Filename.quote stderr_path)
  in
  match Sys.command command with
  | 0 -> ()
  | status ->
      let stderr =
        try read_file stderr_path
        with Sys_error message ->
          Printf.sprintf "ocamlc failed to compile bundled stdlib/core.ml with \
                          status %d: %s"
            status message
      in
      emit_internal_error
        ~message:
          (Printf.sprintf "failed to compile bundled stdlib/core.ml: %s"
             (String.trim stderr));
      cleanup_bundled_stdlib_dir dir;
      exit 3

let compile_to_cmt ~diagnostic_input ~extra_cleanup input =
  let tmp_cmo = Filename.temp_file "Zxcaml_" ".cmo" in
  let tmp_prefix = Filename.remove_extension tmp_cmo in
  let tmp_cmt = tmp_prefix ^ ".cmt" in
  let tmp_stderr = tmp_prefix ^ ".stderr" in
  let stdlib_dir = make_temp_dir "Zxcaml_stdlib_" in
  compile_bundled_stdlib ~dir:stdlib_dir;
  let command =
    Printf.sprintf "%s -bin-annot -I %s -open Core -c %s -o %s 2> %s"
      (ocamlc_command ()) (Filename.quote stdlib_dir) (Filename.quote input)
      (Filename.quote tmp_cmo)
      (Filename.quote tmp_stderr)
  in
  match Sys.command command with
  | 0 ->
      cleanup_bundled_stdlib_dir stdlib_dir;
      (try Sys.remove tmp_stderr with Sys_error _ -> ());
      (tmp_cmo, tmp_cmt)
  | status ->
      let stderr =
        try read_file tmp_stderr
        with Sys_error message ->
          Printf.sprintf "ocamlc -bin-annot failed for %s with status %d: %s"
            input status message
      in
      emit_ocamlc_error ~input:diagnostic_input ~stderr;
      List.iter
        (fun path -> try Sys.remove path with Sys_error _ -> ())
        ([ tmp_cmo; tmp_cmt; Filename.remove_extension tmp_cmo ^ ".cmi"; tmp_stderr ]
        @ extra_cleanup);
      cleanup_bundled_stdlib_dir stdlib_dir;
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
  let input, wire = parse_args () in
  let compile_input, extra_cleanup =
    match preprocess_otest_source input with
    | None -> (input, [])
    | Some transformed -> (transformed, [ transformed ])
  in
  let tmp_cmo, tmp_cmt =
    compile_to_cmt ~diagnostic_input:input ~extra_cleanup compile_input
  in
  let tmp_cmi = Filename.remove_extension tmp_cmo ^ ".cmi" in
  let cleanup_files = [ tmp_cmo; tmp_cmt; tmp_cmi ] @ extra_cleanup in
  try
    let structure = load_implementation tmp_cmt in
    let modul = Zxc_subset.of_structure structure in
    print_string (Zxc_sexp.to_string ~wire modul);
    cleanup cleanup_files
  with
  | Zxc_subset.Unsupported diagnostic ->
      emit_diagnostic diagnostic;
      cleanup cleanup_files;
      exit 1
  | Cmt_format.Error error ->
      let message =
        match error with
        | Cmt_format.Not_a_typedtree path ->
            Printf.sprintf "not a typedtree file: %s" path
      in
      emit_internal_error
        ~message;
      cleanup cleanup_files;
      exit 3
  | Sys_error message ->
      emit_internal_error ~message;
      cleanup cleanup_files;
      exit 3
