#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

inventory=(
  "runtime/zig/programs/hackathon_greet.zig:^pub fn zxcaml_hackathon_greet_process\\("
  "runtime/zig/programs/token_vault.zig:^pub fn zxcaml_token_vault_process\\("
  "runtime/zig/programs/escrow_full.zig:^pub fn zxcaml_escrow_full_process\\("
  "runtime/zig/programs/dao_voting.zig:^pub fn zxcaml_dao_voting_process\\("
  "runtime/zig/programs/ata_transfer.zig:^pub fn zxcaml_ata_transfer_process\\("
  "runtime/zig/programs/spl_burn.zig:^pub fn zxcaml_spl_burn_process\\("
  "runtime/zig/programs/spl_close_account.zig:^pub fn zxcaml_spl_close_account_process\\("
  "runtime/zig/programs/spl_revoke.zig:^pub fn zxcaml_spl_revoke_process\\("
  "runtime/zig/programs/order_book.zig:^pub fn zxcaml_order_book_process\\("
  "runtime/zig/programs/vault.zig:^pub fn zxcaml_vault_process\\("
  "runtime/zig/programs/vault_v2.zig:^pub fn zxcaml_vault_v2_process\\("
)

for item in "${inventory[@]}"; do
  file="${item%%:*}"
  pattern="${item#*:}"
  echo "==> verifying obsolete surface is not exported: $file :: $pattern"
  if rg -n "$pattern" "$ROOT/$file"; then
    echo "ERROR: obsolete runtime surface is still exported from $file" >&2
    exit 1
  fi
done

echo "==> verifying active exception remains public: runtime/zig/programs/transfer_sol.zig"
rg -n '^pub fn zxcaml_transfer_sol_process\(' "$ROOT/runtime/zig/programs/transfer_sol.zig" >/dev/null

echo "SUCCESS: obsolete runtime export inventory is absent from the active surface"
