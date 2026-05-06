let helper = 40

let%test_unit "lsp codelens first passes" = assert (helper + 2 = 42)

let%test_unit "lsp codelens second fails" = assert (helper = 0)

let entrypoint _ = 0
