//! SVM-level integration test for the ZxCaml Clock/Rent sysvar demo.
//!
//! The setup step compiles `examples/clock_rent_demo.ml` to
//! `build/clock_rent_demo.so`.  The test then uses Mollusk's explicit sysvar
//! fixture API to seed Clock and Rent with known values, passes the serialized
//! sysvar accounts to the program, and asserts account 0 receives the selected
//! fields as little-endian u64 words.

use mollusk_svm::Mollusk;
use solana_account::Account;
use solana_instruction::{AccountMeta, Instruction};
use solana_pubkey::Pubkey;
use std::fs;

const PROGRAM_ID_BYTES: [u8; 32] = [48u8; 32];
const EXPECTED_SLOT: u64 = 1_234_567;
const EXPECTED_UNIX_TIMESTAMP: i64 = 1_700_000_123;
const EXPECTED_LAMPORTS_PER_BYTE_YEAR: u64 = 3_480;

fn program_id() -> Pubkey {
    Pubkey::new_from_array(PROGRAM_ID_BYTES)
}

mod bpf_test_support;

fn setup_mollusk() -> Mollusk {
    let elf_path = bpf_test_support::compile_program("clock_rent_demo");
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
    mollusk.sysvars.clock.slot = EXPECTED_SLOT;
    mollusk.sysvars.clock.unix_timestamp = EXPECTED_UNIX_TIMESTAMP;
    #[allow(deprecated)]
    {
        mollusk.sysvars.rent.lamports_per_byte_year = EXPECTED_LAMPORTS_PER_BYTE_YEAR;
    }
    mollusk
}

fn read_u64_le(data: &[u8], offset: usize) -> u64 {
    let mut bytes = [0u8; 8];
    bytes.copy_from_slice(&data[offset..offset + 8]);
    u64::from_le_bytes(bytes)
}

fn read_i64_le(data: &[u8], offset: usize) -> i64 {
    let mut bytes = [0u8; 8];
    bytes.copy_from_slice(&data[offset..offset + 8]);
    i64::from_le_bytes(bytes)
}

#[test]
fn clock_rent_demo_writes_selected_sysvar_fields_to_account_zero() {
    let mollusk = setup_mollusk();
    let output_account = Pubkey::new_unique();
    let (clock_key, clock_account) = mollusk.sysvars.keyed_account_for_clock_sysvar();
    let (rent_key, rent_account) = mollusk.sysvars.keyed_account_for_rent_sysvar();

    let ix = Instruction {
        program_id: program_id(),
        accounts: vec![
            AccountMeta::new(output_account, false),
            AccountMeta::new_readonly(clock_key, false),
            AccountMeta::new_readonly(rent_key, false),
        ],
        data: vec![],
    };

    let result = mollusk.process_instruction(
        &ix,
        &[
            (
                output_account,
                Account {
                    lamports: 1_000_000,
                    data: vec![0u8; 24],
                    owner: program_id(),
                    ..Account::default()
                },
            ),
            (clock_key, clock_account),
            (rent_key, rent_account),
        ],
    );

    assert!(
        !result.program_result.is_err(),
        "clock/rent demo should succeed: {:?}",
        result.program_result
    );

    let output = &result.resulting_accounts[0].1.data;
    assert_eq!(read_u64_le(output, 0), EXPECTED_SLOT);
    assert_eq!(read_i64_le(output, 8), EXPECTED_UNIX_TIMESTAMP);
    assert_eq!(read_u64_le(output, 16), EXPECTED_LAMPORTS_PER_BYTE_YEAR);
}
