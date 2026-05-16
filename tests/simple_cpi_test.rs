//! SVM-level integration tests for ZxCaml CPI fixtures.
//!
//! The setup step compiles the committed caller examples under `examples/`
//! and then exercises them against native/builtin callees inside Mollusk to
//! verify lamport transfer, callee-error propagation, and arbitrary
//! instruction byte preservation.

use mollusk_svm::Mollusk;
use solana_account::Account;
use solana_instruction::{error::InstructionError, AccountMeta, Instruction};
use solana_program_runtime::declare_process_instruction;
use solana_pubkey::Pubkey;
use solana_svm_log_collector::ic_msg;
use std::fs;

const SIMPLE_CPI_PROGRAM_ID_BYTES: [u8; 32] = [3u8; 32];
const ERROR_PROPAGATION_PROGRAM_ID_BYTES: [u8; 32] = [53u8; 32];
const INSTRUCTION_DUMP_PROGRAM_ID_BYTES: [u8; 32] = [54u8; 32];
const ERROR_CALLEE_PROGRAM_ID_BYTES: [u8; 32] = [b'Q'; 32];
const DUMP_CALLEE_PROGRAM_ID_BYTES: [u8; 32] = [b'P'; 32];
const ERROR_RELAY_ACCOUNT_BYTES: [u8; 32] = [0x5A; 32];
const DUMP_READONLY_ACCOUNT_BYTES: [u8; 32] = [b'A'; 32];
const DUMP_WRITABLE_ACCOUNT_BYTES: [u8; 32] = [b'B'; 32];
const DUMP_SIGNER_ACCOUNT_BYTES: [u8; 32] = [b'C'; 32];
const DUMP_WRITABLE_SIGNER_ACCOUNT_BYTES: [u8; 32] = [b'D'; 32];
const ARBITRARY_CPI_DATA: [u8; 7] = [b'A', 0, b'Z', b'?', b'*', b'b', b'!'];
const CALLEE_CUSTOM_ERROR_CODE: u32 = 77;

const SYSTEM_PROGRAM_ID: Pubkey = solana_pubkey::pubkey!("11111111111111111111111111111111");
const NATIVE_LOADER_ID: Pubkey =
    solana_pubkey::pubkey!("NativeLoader1111111111111111111111111111111");

fn simple_cpi_program_id() -> Pubkey {
    Pubkey::new_from_array(SIMPLE_CPI_PROGRAM_ID_BYTES)
}

fn error_propagation_program_id() -> Pubkey {
    Pubkey::new_from_array(ERROR_PROPAGATION_PROGRAM_ID_BYTES)
}

fn instruction_dump_program_id() -> Pubkey {
    Pubkey::new_from_array(INSTRUCTION_DUMP_PROGRAM_ID_BYTES)
}

fn error_callee_program_id() -> Pubkey {
    Pubkey::new_from_array(ERROR_CALLEE_PROGRAM_ID_BYTES)
}

fn dump_callee_program_id() -> Pubkey {
    Pubkey::new_from_array(DUMP_CALLEE_PROGRAM_ID_BYTES)
}

fn error_relay_account() -> Pubkey {
    Pubkey::new_from_array(ERROR_RELAY_ACCOUNT_BYTES)
}

fn dump_readonly_account() -> Pubkey {
    Pubkey::new_from_array(DUMP_READONLY_ACCOUNT_BYTES)
}

fn dump_writable_account() -> Pubkey {
    Pubkey::new_from_array(DUMP_WRITABLE_ACCOUNT_BYTES)
}

fn dump_signer_account() -> Pubkey {
    Pubkey::new_from_array(DUMP_SIGNER_ACCOUNT_BYTES)
}

fn dump_writable_signer_account() -> Pubkey {
    Pubkey::new_from_array(DUMP_WRITABLE_SIGNER_ACCOUNT_BYTES)
}

fn builtin_program_account() -> Account {
    Account {
        executable: true,
        owner: NATIVE_LOADER_ID,
        ..Account::default()
    }
}

fn compile_program(example: &str) -> Vec<u8> {
    let elf_path = bpf_test_support::compile_program(example);
    fs::read(&elf_path).unwrap_or_else(|error| {
        panic!(
            "failed to read sBPF artifact at {}: {}",
            elf_path.display(),
            error
        )
    })
}

fn setup_program(example: &str, pid: Pubkey) -> Mollusk {
    let elf = compile_program(example);
    let loader_v3 = solana_pubkey::pubkey!("BPFLoaderUpgradeab1e11111111111111111111111");
    let mut mollusk = bpf_test_support::new_mollusk();
    mollusk.add_program_with_loader_and_elf(&pid, &loader_v3, &elf);
    mollusk
}

fn expected_instruction_dump() -> Vec<u8> {
    let mut dump = Vec::new();
    dump.extend_from_slice(&DUMP_CALLEE_PROGRAM_ID_BYTES);
    dump.extend_from_slice(&(4u32).to_le_bytes());
    for (key, is_signer, is_writable) in [
        (DUMP_READONLY_ACCOUNT_BYTES, false, false),
        (DUMP_WRITABLE_ACCOUNT_BYTES, false, true),
        (DUMP_SIGNER_ACCOUNT_BYTES, true, false),
        (DUMP_WRITABLE_SIGNER_ACCOUNT_BYTES, true, true),
    ] {
        dump.extend_from_slice(&key);
        dump.push(u8::from(is_signer));
        dump.push(u8::from(is_writable));
    }
    dump.extend_from_slice(&(ARBITRARY_CPI_DATA.len() as u32).to_le_bytes());
    dump.extend_from_slice(&ARBITRARY_CPI_DATA);
    dump
}

declare_process_instruction!(FailingCpiCalleeEntrypoint, 1, |invoke_context| {
    let instruction_context = invoke_context
        .transaction_context
        .get_current_instruction_context()?;
    ic_msg!(
        invoke_context,
        "failing callee invoked for program {}",
        instruction_context.get_program_key()?
    );
    Err(InstructionError::Custom(CALLEE_CUSTOM_ERROR_CODE))
});

declare_process_instruction!(DumpingCpiCalleeEntrypoint, 1, |invoke_context| {
    let instruction_context = invoke_context
        .transaction_context
        .get_current_instruction_context()?;
    let account_count = instruction_context.get_number_of_instruction_accounts();
    let program_id = *instruction_context.get_program_key()?;
    let mut dump = Vec::new();
    dump.extend_from_slice(program_id.as_ref());
    dump.extend_from_slice(&(u32::from(account_count)).to_le_bytes());
    for index in 0..account_count {
        dump.extend_from_slice(
            instruction_context
                .get_key_of_instruction_account(index)?
                .as_ref(),
        );
        dump.push(u8::from(
            instruction_context.is_instruction_account_signer(index)?,
        ));
        dump.push(u8::from(
            instruction_context.is_instruction_account_writable(index)?,
        ));
    }

    let data = instruction_context.get_instruction_data();
    let data_len = data.len();
    dump.extend_from_slice(&(data.len() as u32).to_le_bytes());
    dump.extend_from_slice(data);
    let _ = instruction_context;
    invoke_context.transaction_context.set_return_data(program_id, dump)?;
    ic_msg!(
        invoke_context,
        "dumped {} metas and {} data bytes",
        account_count,
        data_len
    );
    Ok(())
});

mod bpf_test_support;

#[test]
fn test_simple_cpi_transfers_one_lamport() {
    let mut mollusk = setup_program("simple_cpi", simple_cpi_program_id());
    mollusk
        .program_cache
        .add_builtin(mollusk_svm::program::Builtin {
            program_id: SYSTEM_PROGRAM_ID,
            name: "system_program",
            entrypoint: solana_system_program::system_processor::Entrypoint::vm,
        });

    let from = Pubkey::new_unique();
    let to = Pubkey::new_unique();
    let initial_from_lamports = 1_000_000_000;
    let initial_to_lamports = 10;

    let mut transfer_data = vec![2, 0, 0, 0];
    transfer_data.extend_from_slice(&1u64.to_le_bytes());

    let ix = Instruction {
        program_id: simple_cpi_program_id(),
        accounts: vec![
            AccountMeta::new(from, true),
            AccountMeta::new(to, false),
            AccountMeta::new_readonly(SYSTEM_PROGRAM_ID, false),
        ],
        data: transfer_data,
    };

    let from_acc = Account {
        lamports: initial_from_lamports,
        ..Account::default()
    };
    let to_acc = Account {
        lamports: initial_to_lamports,
        ..Account::default()
    };

    let result = mollusk.process_instruction(
        &ix,
        &[
            (from, from_acc),
            (to, to_acc),
            (SYSTEM_PROGRAM_ID, builtin_program_account()),
        ],
    );

    assert!(
        !result.program_result.is_err(),
        "simple CPI transfer should succeed: {:?}",
        result.program_result
    );

    let from_post = &result.resulting_accounts[0].1;
    let to_post = &result.resulting_accounts[1].1;
    assert_eq!(from_post.lamports, initial_from_lamports - 1);
    assert_eq!(to_post.lamports, initial_to_lamports + 1);
}

#[test]
fn simple_cpi_propagates_callee_custom_error() {
    let mut mollusk = setup_program(
        "simple_cpi_error_propagation",
        error_propagation_program_id(),
    );
    mollusk
        .program_cache
        .add_builtin(mollusk_svm::program::Builtin {
            program_id: error_callee_program_id(),
            name: "failing_cpi_callee",
            entrypoint: FailingCpiCalleeEntrypoint::vm,
        });

    let result = mollusk.process_instruction(
        &Instruction {
            program_id: error_propagation_program_id(),
            accounts: vec![
                AccountMeta::new_readonly(error_relay_account(), false),
                AccountMeta::new_readonly(error_callee_program_id(), false),
            ],
            data: vec![],
        },
        &[
            (error_relay_account(), Account::default()),
            (error_callee_program_id(), builtin_program_account()),
        ],
    );

    assert!(
        result.raw_result.is_err(),
        "callee error should fail the outer instruction: {:?}",
        result.raw_result
    );
    assert_eq!(
        format!("{:?}", result.program_result),
        format!("Failure(Custom({CALLEE_CUSTOM_ERROR_CODE}))")
    );
}

#[test]
fn simple_cpi_preserves_arbitrary_instruction_fields() {
    let mut mollusk = setup_program(
        "simple_cpi_instruction_dump",
        instruction_dump_program_id(),
    );
    mollusk
        .program_cache
        .add_builtin(mollusk_svm::program::Builtin {
            program_id: dump_callee_program_id(),
            name: "dumping_cpi_callee",
            entrypoint: DumpingCpiCalleeEntrypoint::vm,
        });

    let result = mollusk.process_instruction(
        &Instruction {
            program_id: instruction_dump_program_id(),
            accounts: vec![
                AccountMeta::new_readonly(dump_readonly_account(), false),
                AccountMeta::new(dump_writable_account(), false),
                AccountMeta::new_readonly(dump_signer_account(), true),
                AccountMeta::new(dump_writable_signer_account(), true),
                AccountMeta::new_readonly(dump_callee_program_id(), false),
            ],
            data: vec![],
        },
        &[
            (dump_readonly_account(), Account::default()),
            (dump_writable_account(), Account::default()),
            (dump_signer_account(), Account::default()),
            (dump_writable_signer_account(), Account::default()),
            (dump_callee_program_id(), builtin_program_account()),
        ],
    );

    assert!(
        !result.program_result.is_err(),
        "arbitrary instruction CPI should succeed: {:?}",
        result.program_result
    );
    assert_eq!(result.return_data, expected_instruction_dump());
}
