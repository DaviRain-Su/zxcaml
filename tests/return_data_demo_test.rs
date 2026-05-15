//! SVM-level integration test for the ZxCaml return-data syscall demo.
//!
//! The setup step compiles `examples/return_data_demo.ml` to
//! `build/return_data_demo.so`. The test invokes the program with a
//! deterministic instruction-data payload, then asserts the program copies that
//! payload through Solana return-data and into writable account 0.

use mollusk_svm::Mollusk;
use solana_account::Account;
use solana_instruction::{AccountMeta, Instruction};
use solana_pubkey::Pubkey;
use std::fs;

const PROGRAM_ID_BYTES: [u8; 32] = [53u8; 32];
const INSTRUCTION_DATA: [u8; 16] = [
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
];

fn program_id() -> Pubkey {
    Pubkey::new_from_array(PROGRAM_ID_BYTES)
}

mod bpf_test_support;

fn setup_mollusk() -> Mollusk {
    let elf_path = bpf_test_support::compile_program("return_data_demo");
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
}

#[test]
fn return_data_demo_round_trips_instruction_data() {
    let mollusk = setup_mollusk();
    let output_account = Pubkey::new_unique();

    let ix = Instruction {
        program_id: program_id(),
        accounts: vec![AccountMeta::new(output_account, false)],
        data: INSTRUCTION_DATA.to_vec(),
    };

    let result = mollusk.process_instruction(
        &ix,
        &[(
            output_account,
            Account {
                lamports: 1_000_000,
                data: vec![0u8; INSTRUCTION_DATA.len()],
                owner: program_id(),
                ..Account::default()
            },
        )],
    );

    assert!(
        !result.program_result.is_err(),
        "return-data demo should succeed: {:?}",
        result.program_result
    );

    assert_eq!(result.return_data, INSTRUCTION_DATA);

    let output = &result.resulting_accounts[0].1.data;
    assert_eq!(output.as_slice(), INSTRUCTION_DATA);
}
