# Examples

This directory is the user-facing `.ml` example surface for ZxCaml.
The exact recursive source of truth for the M3 examples/tests organization work
is [`examples/ml-layout-manifest.tsv`](./ml-layout-manifest.tsv), which
classifies every `.ml` file in the example/test workflow as one of:

- `user_example`
- `acceptance_fixture`
- `compiler_corpus`
- `solana_harness_source`
- `excluded_historical`

Compatibility route: M3 keeps every pre-existing example/test path stable in
place, so existing docs, scripts, Cargo tests, Zig tests, LSP fixtures, and
Surfpool harnesses can keep using their current paths without a migration shim.

## User-facing examples

Top-level `examples/*.ml` entries are the discoverable user examples and the
inputs to `./scripts/check_examples_corpus.sh`.

<!-- user-examples:start -->
- [`examples/account_guard.ml`](./account_guard.ml)
- [`examples/account_parser_view.ml`](./account_parser_view.ml)
- [`examples/arith_wrap.ml`](./arith_wrap.ml)
- [`examples/array_mutation_demo.ml`](./array_mutation_demo.ml)
- [`examples/assert_demo.ml`](./assert_demo.ml)
- [`examples/ata_transfer.ml`](./ata_transfer.ml)
- [`examples/bitwise_ops.ml`](./bitwise_ops.ml)
- [`examples/blake3_demo.ml`](./blake3_demo.ml)
- [`examples/box_bool_adt.ml`](./box_bool_adt.ml)
- [`examples/bytes_blit_fill.ml`](./bytes_blit_fill.ml)
- [`examples/bytes_le_codec.ml`](./bytes_le_codec.ml)
- [`examples/bytes_le_decode.ml`](./bytes_le_decode.ml)
- [`examples/bytes_mutable.ml`](./bytes_mutable.ml)
- [`examples/bytes_read.ml`](./bytes_read.ml)
- [`examples/captured_loop.ml`](./captured_loop.ml)
- [`examples/clock_rent_demo.ml`](./clock_rent_demo.ml)
- [`examples/closure_adt.ml`](./closure_adt.ml)
- [`examples/combined_flow.ml`](./combined_flow.ml)
- [`examples/compute_units_demo.ml`](./compute_units_demo.ml)
- [`examples/counter.ml`](./counter.ml)
- [`examples/counter_v2.ml`](./counter_v2.ml)
- [`examples/crypto_demo.ml`](./crypto_demo.ml)
- [`examples/crypto_equivalence.ml`](./crypto_equivalence.ml)
- [`examples/dao_voting.ml`](./dao_voting.ml)
- [`examples/demo.ml`](./demo.ml)
- [`examples/div_zero.ml`](./div_zero.ml)
- [`examples/enum_adt.ml`](./enum_adt.ml)
- [`examples/escrow_full.ml`](./escrow_full.ml)
- [`examples/external_demo.ml`](./external_demo.ml)
- [`examples/factorial.ml`](./factorial.ml)
- [`examples/first_class_closure_pass.ml`](./first_class_closure_pass.ml)
- [`examples/first_class_closure_return.ml`](./first_class_closure_return.ml)
- [`examples/fixed_amm_quote.ml`](./fixed_amm_quote.ml)
- [`examples/for_loop_demo.ml`](./for_loop_demo.ml)
- [`examples/format_demo.ml`](./format_demo.ml)
- [`examples/guard_match.ml`](./guard_match.ml)
- [`examples/hackathon_greet.ml`](./hackathon_greet.ml)
- [`examples/hello.ml`](./hello.ml)
- [`examples/instruction_introspect_demo.ml`](./instruction_introspect_demo.ml)
- [`examples/keccak_demo.ml`](./keccak_demo.ml)
- [`examples/lambda_type_demo.ml`](./lambda_type_demo.ml)
- [`examples/let_basic.ml`](./let_basic.ml)
- [`examples/list_sum.ml`](./list_sum.ml)
- [`examples/log64_boundaries.ml`](./log64_boundaries.ml)
- [`examples/log_account_key.ml`](./log_account_key.ml)
- [`examples/log_accounts.ml`](./log_accounts.ml)
- [`examples/logonly.ml`](./logonly.ml)
- [`examples/m0_zero.ml`](./m0_zero.ml)
- [`examples/mtf1_account_lamports_mutation.ml`](./mtf1_account_lamports_mutation.ml)
- [`examples/mtf1_pure_numeric.ml`](./mtf1_pure_numeric.ml)
- [`examples/mtf2_near_no_storage.ml`](./mtf2_near_no_storage.ml)
- [`examples/multi_ix.ml`](./multi_ix.ml)
- [`examples/mutable_state_stress.ml`](./mutable_state_stress.ml)
- [`examples/mutual_rec.ml`](./mutual_rec.ml)
- [`examples/nested_let.ml`](./nested_let.ml)
- [`examples/nested_pattern.ml`](./nested_pattern.ml)
- [`examples/noop.ml`](./noop.ml)
- [`examples/option_adt.ml`](./option_adt.ml)
- [`examples/option_basic.ml`](./option_basic.ml)
- [`examples/option_chain.ml`](./option_chain.ml)
- [`examples/option_construct.ml`](./option_construct.ml)
- [`examples/order_book.ml`](./order_book.ml)
- [`examples/pda_storage.ml`](./pda_storage.ml)
- [`examples/record_nested.ml`](./record_nested.ml)
- [`examples/record_param_box.ml`](./record_param_box.ml)
- [`examples/record_person.ml`](./record_person.ml)
- [`examples/ref_loop_demo.ml`](./ref_loop_demo.ml)
- [`examples/region_demo.ml`](./region_demo.ml)
- [`examples/result_basic.ml`](./result_basic.ml)
- [`examples/return_data_demo.ml`](./return_data_demo.ml)
- [`examples/secp_recover_demo.ml`](./secp_recover_demo.ml)
- [`examples/simple_cpi.ml`](./simple_cpi.ml)
- [`examples/simple_cpi_error_propagation.ml`](./simple_cpi_error_propagation.ml)
- [`examples/simple_cpi_instruction_dump.ml`](./simple_cpi_instruction_dump.ml)
- [`examples/solana_hello.ml`](./solana_hello.ml)
- [`examples/solana_instruction_encode.ml`](./solana_instruction_encode.ml)
- [`examples/spl_burn.ml`](./spl_burn.ml)
- [`examples/spl_close_account.ml`](./spl_close_account.ml)
- [`examples/spl_revoke.ml`](./spl_revoke.ml)
- [`examples/spl_token_transfer.ml`](./spl_token_transfer.ml)
- [`examples/spl_transfer_encode.ml`](./spl_transfer_encode.ml)
- [`examples/spl_transfer_pure_ocaml.ml`](./spl_transfer_pure_ocaml.ml)
- [`examples/stake_epoch_demo.ml`](./stake_epoch_demo.ml)
- [`examples/stdlib_f32.ml`](./stdlib_f32.ml)
- [`examples/stdlib_list.ml`](./stdlib_list.ml)
- [`examples/string_demo.ml`](./string_demo.ml)
- [`examples/syscall_equivalence.ml`](./syscall_equivalence.ml)
- [`examples/syscall_test.ml`](./syscall_test.ml)
- [`examples/system_transfer_pure_ocaml.ml`](./system_transfer_pure_ocaml.ml)
- [`examples/tail_rec.ml`](./tail_rec.ml)
- [`examples/token_vault.ml`](./token_vault.ml)
- [`examples/transfer_sol.ml`](./transfer_sol.ml)
- [`examples/tree_adt.ml`](./tree_adt.ml)
- [`examples/tuple_basic.ml`](./tuple_basic.ml)
- [`examples/vault.ml`](./vault.ml)
- [`examples/vault_v2.ml`](./vault_v2.ml)
- [`examples/while_loop_demo.ml`](./while_loop_demo.ml)
<!-- user-examples:end -->

## `omlz test` acceptance fixtures

`examples/tests/*.ml` remains the default `omlz test` discovery surface.
These files stay runnable through the same public entrypoint, but they are
validation fixtures rather than default end-user examples.

<!-- acceptance-fixtures:start -->
- [`examples/tests/account_helpers_test.ml`](./tests/account_helpers_test.ml)
- [`examples/tests/arith_overflow.ml`](./tests/arith_overflow.ml)
- [`examples/tests/fixed_test.ml`](./tests/fixed_test.ml)
- [`examples/tests/format_test.ml`](./tests/format_test.ml)
- [`examples/tests/list_ops.ml`](./tests/list_ops.ml)
- [`examples/tests/mutable_state_test.ml`](./tests/mutable_state_test.ml)
- [`examples/tests/pda_helpers.ml`](./tests/pda_helpers.ml)
- [`examples/tests/prop_int_add.ml`](./tests/prop_int_add.ml)
- [`examples/tests/prop_list_rev.ml`](./tests/prop_list_rev.ml)
- [`examples/tests/prop_string_concat.ml`](./tests/prop_string_concat.ml)
<!-- acceptance-fixtures:end -->

## Non-user validation surfaces

The manifest also tracks recursive validation-only `.ml` inputs so test-only
fixtures stay separate from the user example catalog.

<!-- validation-summary:start -->
- `compiler_corpus`: 148 files under `runtime/lsp/fixtures/`, `tests/codegen/`, `tests/fixtures/`, `tests/golden/`, `tests/idl/`, `tests/lsp/`, and `tests/ui/`.
- `solana_harness_source`: 5 files under `tests/solana/`.
- `excluded_historical`: 1 file kept out of the default user corpus (`examples/m0_unsupported.ml`).
<!-- validation-summary:end -->

## Regeneration controls

- Check manifest + README synchronization:
  `python3 scripts/check_examples_layout.py`
- Regenerate the managed README blocks explicitly:
  `python3 scripts/check_examples_layout.py --write`
