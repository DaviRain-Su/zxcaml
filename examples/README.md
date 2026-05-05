# Examples

This directory is the checked-in `.ml` example corpus for ZxCaml. The table
below lists every `examples/*.ml` source file and tags the capabilities each
file clearly exercises.

Capability tag vocabulary: `Closure`, `ADT`, `PDA`, `CPI`, `SPL-Token`, `TCO`,
`Mutual-Rec`, `Region`, `Assert`.

## M-EX2 additions

- [`examples/dao_voting.ml`](./dao_voting.ml) — DAO proposal and vote-record PDAs with yes/no vote counting and double-vote rejection.
- [`examples/ata_transfer.ml`](./ata_transfer.ml) — Associated Token Account create-idempotent flow followed by a mocked SPL-Token transfer.
- [`examples/order_book.ml`](./order_book.ml) — Maker/taker order PDA with full and partial fill token-balance flows.

| Example | Capability tags | zignocchio counterpart |
|---|---|---|
| [`arith_wrap.ml`](./arith_wrap.ml) | — | — |
| [`assert_demo.ml`](./assert_demo.ml) | ADT, Assert | — |
| [`ata_transfer.ml`](./ata_transfer.ml) | CPI, SPL-Token | — |
| [`box_bool_adt.ml`](./box_bool_adt.ml) | ADT | — |
| [`captured_loop.ml`](./captured_loop.ml) | Closure | — |
| [`closure_adt.ml`](./closure_adt.ml) | Closure, ADT | — |
| [`counter.ml`](./counter.ml) | ADT | — |
| [`counter_v2.ml`](./counter_v2.ml) | ADT, PDA | [`examples/counter/lib.zig`](https://github.com/DaviRain-Su/zignocchio/blob/main/examples/counter/lib.zig) |
| [`crypto_demo.ml`](./crypto_demo.ml) | — | — |
| [`dao_voting.ml`](./dao_voting.ml) | PDA | — |
| [`demo.ml`](./demo.ml) | — | — |
| [`div_zero.ml`](./div_zero.ml) | — | — |
| [`enum_adt.ml`](./enum_adt.ml) | ADT | — |
| [`escrow_full.ml`](./escrow_full.ml) | PDA, CPI | [`examples/escrow/`](https://github.com/DaviRain-Su/zignocchio/tree/main/examples/escrow) |
| [`external_demo.ml`](./external_demo.ml) | — | — |
| [`factorial.ml`](./factorial.ml) | — | — |
| [`first_class_closure_pass.ml`](./first_class_closure_pass.ml) | Closure | — |
| [`first_class_closure_return.ml`](./first_class_closure_return.ml) | Closure | — |
| [`guard_match.ml`](./guard_match.ml) | ADT | — |
| [`hackathon_greet.ml`](./hackathon_greet.ml) | PDA | — |
| [`hello.ml`](./hello.ml) | — | — |
| [`let_basic.ml`](./let_basic.ml) | — | — |
| [`list_sum.ml`](./list_sum.ml) | ADT | — |
| [`log_accounts.ml`](./log_accounts.ml) | — | — |
| [`logonly.ml`](./logonly.ml) | — | [`examples/logonly/lib.zig`](https://github.com/DaviRain-Su/zignocchio/blob/main/examples/logonly/lib.zig) |
| [`m0_unsupported.ml`](./m0_unsupported.ml) | — | — |
| [`m0_zero.ml`](./m0_zero.ml) | — | — |
| [`multi_ix.ml`](./multi_ix.ml) | ADT | — |
| [`mutual_rec.ml`](./mutual_rec.ml) | Mutual-Rec | — |
| [`nested_let.ml`](./nested_let.ml) | — | — |
| [`nested_pattern.ml`](./nested_pattern.ml) | ADT | — |
| [`noop.ml`](./noop.ml) | — | [`examples/noop/lib.zig`](https://github.com/DaviRain-Su/zignocchio/blob/main/examples/noop/lib.zig) |
| [`option_adt.ml`](./option_adt.ml) | ADT | — |
| [`option_basic.ml`](./option_basic.ml) | ADT | — |
| [`option_chain.ml`](./option_chain.ml) | ADT | — |
| [`option_construct.ml`](./option_construct.ml) | ADT | — |
| [`order_book.ml`](./order_book.ml) | PDA, CPI, SPL-Token | — |
| [`pda_storage.ml`](./pda_storage.ml) | PDA | [`examples/pda-storage/lib.zig`](https://github.com/DaviRain-Su/zignocchio/blob/main/examples/pda-storage/lib.zig) |
| [`record_nested.ml`](./record_nested.ml) | ADT | — |
| [`record_param_box.ml`](./record_param_box.ml) | ADT | — |
| [`record_person.ml`](./record_person.ml) | ADT | — |
| [`region_demo.ml`](./region_demo.ml) | Region | — |
| [`result_basic.ml`](./result_basic.ml) | ADT | — |
| [`simple_cpi.ml`](./simple_cpi.ml) | PDA, CPI | — |
| [`solana_hello.ml`](./solana_hello.ml) | — | — |
| [`spl_token_transfer.ml`](./spl_token_transfer.ml) | CPI, SPL-Token | — |
| [`stdlib_f32.ml`](./stdlib_f32.ml) | ADT | — |
| [`stdlib_list.ml`](./stdlib_list.ml) | Closure, ADT | — |
| [`string_demo.ml`](./string_demo.ml) | — | — |
| [`syscall_test.ml`](./syscall_test.ml) | — | — |
| [`tail_rec.ml`](./tail_rec.ml) | TCO | — |
| [`token_vault.ml`](./token_vault.ml) | PDA, CPI, SPL-Token | [`examples/token-vault/`](https://github.com/DaviRain-Su/zignocchio/tree/main/examples/token-vault) |
| [`transfer_sol.ml`](./transfer_sol.ml) | CPI | [`examples/transfer-sol/lib.zig`](https://github.com/DaviRain-Su/zignocchio/blob/main/examples/transfer-sol/lib.zig) |
| [`tree_adt.ml`](./tree_adt.ml) | ADT | — |
| [`tuple_basic.ml`](./tuple_basic.ml) | ADT | — |
| [`vault.ml`](./vault.ml) | ADT, PDA, CPI | [`examples/vault/`](https://github.com/DaviRain-Su/zignocchio/tree/main/examples/vault) |
| [`vault_v2.ml`](./vault_v2.ml) | PDA, CPI | [`examples/vault/`](https://github.com/DaviRain-Su/zignocchio/tree/main/examples/vault) |
