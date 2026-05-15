//! SVM-level integration test for the ZxCaml vault program.
//!
//! The setup step compiles `examples/vault.ml` to `build/vault.so` with the
//! local `omlz` binary, then verifies deposit and withdraw instructions move
//! lamports between an owner and a PDA vault via the System Program.

use mollusk_svm::Mollusk;
use solana_account::Account;
use solana_instruction::{AccountMeta, Instruction};
use solana_pubkey::Pubkey;
use std::fs;

const PROGRAM_ID_BYTES: [u8; 32] = [5u8; 32];
const SYSTEM_PROGRAM_ID: Pubkey = solana_pubkey::pubkey!("11111111111111111111111111111111");
const NATIVE_LOADER_ID: Pubkey =
    solana_pubkey::pubkey!("NativeLoader1111111111111111111111111111111");

fn program_id() -> Pubkey {
    Pubkey::new_from_array(PROGRAM_ID_BYTES)
}

fn owner_and_vault_pda() -> (Pubkey, Pubkey) {
    loop {
        let owner = Pubkey::new_unique();
        if let Ok(vault) =
            Pubkey::create_program_address(&[b"vault", owner.as_ref()], &program_id())
        {
            return (owner, vault);
        }
    }
}

mod bpf_test_support;

fn setup_mollusk() -> Mollusk {
    let elf_path = bpf_test_support::compile_program("vault");
    let elf = fs::read(&elf_path).unwrap_or_else(|error| {
        panic!(
            "failed to read sBPF artifact at {}: {}",
            elf_path.display(),
            error
        )
    });
    let pid = program_id();
    let loader_v3 = solana_pubkey::pubkey!("BPFLoaderUpgradeab1e11111111111111111111111");
    let mut mollusk = bpf_test_support::new_mollusk();
    mollusk.add_program_with_loader_and_elf(&pid, &loader_v3, &elf);
    mollusk
        .program_cache
        .add_builtin(mollusk_svm::program::Builtin {
            program_id: SYSTEM_PROGRAM_ID,
            name: "system_program",
            entrypoint: solana_system_program::system_processor::Entrypoint::vm,
        });
    mollusk
}

#[test]
fn vault_test_deposit_increases_vault_and_withdraw_returns_funds() {
    let mollusk = setup_mollusk();
    let (owner, vault) = owner_and_vault_pda();
    let initial_owner_lamports = 1_000_000_000;
    let deposit_amount = 123_456u64;

    let mut deposit_data = vec![0];
    deposit_data.extend_from_slice(&deposit_amount.to_le_bytes());
    let deposit_ix = Instruction {
        program_id: program_id(),
        accounts: vec![
            AccountMeta::new(owner, true),
            AccountMeta::new(vault, false),
            AccountMeta::new_readonly(SYSTEM_PROGRAM_ID, false),
        ],
        data: deposit_data,
    };

    let owner_account = Account {
        lamports: initial_owner_lamports,
        owner: SYSTEM_PROGRAM_ID,
        ..Account::default()
    };
    let vault_account = Account {
        lamports: 0,
        owner: SYSTEM_PROGRAM_ID,
        ..Account::default()
    };
    let system_account = Account {
        executable: true,
        owner: NATIVE_LOADER_ID,
        ..Account::default()
    };

    let deposit_result = mollusk.process_instruction(
        &deposit_ix,
        &[
            (owner, owner_account),
            (vault, vault_account),
            (SYSTEM_PROGRAM_ID, system_account),
        ],
    );

    assert!(
        !deposit_result.program_result.is_err(),
        "vault deposit should succeed: {:?}",
        deposit_result.program_result
    );
    let owner_after_deposit = &deposit_result.resulting_accounts[0].1;
    let vault_after_deposit = &deposit_result.resulting_accounts[1].1;
    assert_eq!(
        owner_after_deposit.lamports,
        initial_owner_lamports - deposit_amount
    );
    assert_eq!(vault_after_deposit.lamports, deposit_amount);

    let withdraw_ix = Instruction {
        program_id: program_id(),
        accounts: vec![
            AccountMeta::new(owner, true),
            AccountMeta::new(vault, false),
            AccountMeta::new_readonly(SYSTEM_PROGRAM_ID, false),
        ],
        data: vec![1],
    };

    let withdraw_result = mollusk.process_instruction(
        &withdraw_ix,
        &[
            (owner, deposit_result.resulting_accounts[0].1.clone()),
            (vault, deposit_result.resulting_accounts[1].1.clone()),
            (
                SYSTEM_PROGRAM_ID,
                deposit_result.resulting_accounts[2].1.clone(),
            ),
        ],
    );

    assert!(
        !withdraw_result.program_result.is_err(),
        "vault withdraw should succeed: {:?}",
        withdraw_result.program_result
    );
    let owner_after_withdraw = &withdraw_result.resulting_accounts[0].1;
    let vault_after_withdraw = &withdraw_result.resulting_accounts[1].1;
    assert_eq!(owner_after_withdraw.lamports, initial_owner_lamports);
    assert_eq!(vault_after_withdraw.lamports, 0);
}
