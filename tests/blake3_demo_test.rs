//! SVM-level integration test for the ZxCaml BLAKE3 hash demo.
//!
//! The setup step compiles `examples/blake3_demo.ml` to `build/blake3_demo.so`
//! with the local `omlz` binary, then verifies that the BPF program hashes the
//! instruction-data bytes and writes the fixed 32-byte BLAKE3 digest into
//! account 0.

use mollusk_svm::Mollusk;
use solana_account::Account;
use solana_instruction::{AccountMeta, Instruction};
use solana_pubkey::Pubkey;
use std::fs;

const PROGRAM_ID_BYTES: [u8; 32] = [41u8; 32];
const HASH_INPUT: &[u8] = b"zxcaml hash demo";
// Precomputed with Zig std.crypto.hash.Blake3 over b"zxcaml hash demo".
const EXPECTED_BLAKE3: [u8; 32] = [
    0x65, 0xd3, 0xe0, 0xc7, 0x65, 0xad, 0x99, 0xad, 0xcf, 0xbc, 0xc6, 0xc0, 0xf8, 0xaa, 0x88, 0xc7,
    0x33, 0x5e, 0xfb, 0xdc, 0xed, 0x63, 0x34, 0x51, 0xdf, 0xe7, 0x8b, 0x86, 0xf0, 0x7e, 0x00, 0x0b,
];

fn program_id() -> Pubkey {
    Pubkey::new_from_array(PROGRAM_ID_BYTES)
}

mod bpf_test_support;

fn setup_mollusk() -> Mollusk {
    let elf_path = bpf_test_support::compile_program("blake3_demo");
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
fn blake3_demo_writes_instruction_data_digest_to_account_zero() {
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
        "blake3 demo should succeed: {:?}",
        result.program_result
    );

    let output = &result.resulting_accounts[0].1.data;
    assert_eq!(&output[0..32], EXPECTED_BLAKE3.as_slice());
}
