//! SVM-level integration test for the ZxCaml Keccak hash demo.
//!
//! The setup step compiles `examples/keccak_demo.ml` to `build/keccak_demo.so`
//! with the local `omlz` binary, then verifies that the BPF program hashes the
//! instruction-data bytes and writes the 32-byte Keccak digest into account 0.

use mollusk_svm::Mollusk;
use solana_account::Account;
use solana_instruction::{AccountMeta, Instruction};
use solana_pubkey::Pubkey;
use std::fs;

const PROGRAM_ID_BYTES: [u8; 32] = [40u8; 32];
const HASH_INPUT: &[u8] = b"zxcaml hash demo";
// Precomputed with Python pycryptodome:
// Crypto.Hash.keccak.new(digest_bits=256).update(b"zxcaml hash demo").hexdigest()
const EXPECTED_KECCAK: [u8; 32] = [
    0x5f, 0x1a, 0xd4, 0xd2, 0x29, 0x0d, 0x5e, 0x49, 0x60, 0x89, 0x2b, 0xd9, 0x7e, 0x60, 0x59, 0x72,
    0x5a, 0xa2, 0xf2, 0xac, 0x59, 0x9d, 0x86, 0xe7, 0x84, 0x9e, 0xbd, 0x70, 0x48, 0xd9, 0x86, 0x7a,
];

fn program_id() -> Pubkey {
    Pubkey::new_from_array(PROGRAM_ID_BYTES)
}

mod bpf_test_support;

fn setup_mollusk() -> Mollusk {
    let elf_path = bpf_test_support::compile_program("keccak_demo");
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
fn keccak_demo_writes_instruction_data_digest_to_account_zero() {
    let mollusk = setup_mollusk();
    let output_account = Pubkey::new_unique();

    let ix = Instruction {
        program_id: program_id(),
        accounts: vec![AccountMeta::new(output_account, false)],
        data: HASH_INPUT.to_vec(),
    };

    let result = mollusk.process_instruction(
        &ix,
        &[(
            output_account,
            Account {
                lamports: 1_000_000,
                data: vec![0u8; 32],
                owner: program_id(),
                ..Account::default()
            },
        )],
    );

    assert!(
        !result.program_result.is_err(),
        "keccak demo should succeed: {:?}",
        result.program_result
    );

    let output = &result.resulting_accounts[0].1.data;
    assert_eq!(&output[0..32], EXPECTED_KECCAK.as_slice());
}
