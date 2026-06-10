open Multifile_dup_util

let shared_name x = x + 2

let entrypoint _input = shared_name 1
