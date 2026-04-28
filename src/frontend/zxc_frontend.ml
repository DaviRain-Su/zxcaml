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
    "@[<h>{\"file\":%a,\"line\":%d,\"col\":%d,\"severity\":%a,\"message\":%a,\
     \"node_kind\":%a%a}@]@."
    pp_json_string loc.file loc.line loc.col pp_json_string diagnostic.severity
    pp_json_string diagnostic.message pp_json_string diagnostic.node_kind
    pp_optional_field diagnostic.hint

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

let parse_int_at s start =
  let len = String.length s in
  let rec advance index =
    if index < len then
      match s.[index] with '0' .. '9' -> advance (index + 1) | _ -> index
    else index
  in
  let finish = advance start in
  if finish = start then None
  else int_of_string_opt (String.sub s start (finish - start))

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
        let col =
          match find_sub_from line chars_prefix file_end with
          | Some index -> parse_int_at line (index + String.length chars_prefix)
          | None -> None
        in
        let line_number = Option.value line_number ~default:1 in
        let col = Option.value col ~default:0 in
        { Zxc_subset.file; line = line_number; col; end_line = line_number; end_col = col }
      with Invalid_argument _ ->
        { Zxc_subset.file = input; line = 1; col = 0; end_line = 1; end_col = 0 })

let parse_ocamlc_message stderr =
  match
    find_line
      (fun line -> starts_with ~prefix:"Error:" (String.trim line))
      stderr
  with
  | Some line ->
      let trimmed = String.trim line in
      String.trim
        (String.sub trimmed (String.length "Error:")
           (String.length trimmed - String.length "Error:"))
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

let absolute_path path =
  if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path else path

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

let compile_to_cmt input =
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
      emit_ocamlc_error ~input ~stderr;
      List.iter
        (fun path -> try Sys.remove path with Sys_error _ -> ())
        [ tmp_cmo; tmp_cmt; Filename.remove_extension tmp_cmo ^ ".cmi"; tmp_stderr ];
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
