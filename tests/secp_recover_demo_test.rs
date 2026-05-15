//! SVM-level integration test for the ZxCaml secp256k1 recovery demo.
//!
//! The setup step compiles `examples/secp_recover_demo.ml` to
//! `build/secp_recover_demo.so` with the local `omlz` binary, then verifies
//! that the BPF program parses `(hash, recovery_id, signature)` from
//! instruction data, runs `secp256k1_recover`, and writes the recovered
//! 64-byte uncompressed secp256k1 public key into account 0.

use mollusk_svm::Mollusk;
use solana_account::Account;
use solana_instruction::{AccountMeta, Instruction};
use solana_pubkey::Pubkey;
use std::fs;

const PROGRAM_ID_BYTES: [u8; 32] = [42u8; 32];

// fixture from: https://github.com/bitcoin-core/secp256k1/blob/master/src/modules/recovery/tests_impl.h
// ECDSA test vector: `test_ecdsa_recovery_edge_cases` uses this 32-byte
// message/hash and compact 64-byte signature; only recovery_id=1 succeeds.
const HASH: [u8; 32] = *b"This is a very secret message...";
const RECOVERY_ID: u8 = 1;
const SIGNATURE: [u8; 64] = [
    0x67, 0xcb, 0x28, 0x5f, 0x9c, 0xd1, 0x94, 0xe8, 0x40, 0xd6, 0x29, 0x39, 0x7a, 0xf5, 0x56, 0x96,
    0x62, 0xfd, 0xe4, 0x46, 0x49, 0x99, 0x59, 0x63, 0x17, 0x9a, 0x7d, 0xd1, 0x7b, 0xd2, 0x35, 0x32,
    0x4b, 0x1b, 0x7d, 0xf3, 0x4c, 0xe1, 0xf6, 0x8e, 0x69, 0x4f, 0xf6, 0xf1, 0x1a, 0xc7, 0x51, 0xdd,
    0x7d, 0xd7, 0x3e, 0x38, 0x7e, 0xe4, 0xfc, 0x86, 0x6e, 0x1b, 0xe8, 0xec, 0xc7, 0xdd, 0x95, 0x57,
];
const EXPECTED_PUBKEY: [u8; 64] = [
    134, 135, 74, 107, 36, 167, 84, 98, 113, 22, 86, 14, 122, 225, 92, 214, 158, 179, 62, 115, 180,
    216, 200, 16, 51, 178, 124, 47, 169, 207, 93, 28, 225, 63, 25, 250, 141, 234, 13, 26, 227, 232,
    76, 145, 20, 108, 51, 134, 143, 135, 115, 14, 49, 187, 72, 110, 179, 112, 5, 209, 64, 204, 122,
    85,
];

fn program_id() -> Pubkey {
    Pubkey::new_from_array(PROGRAM_ID_BYTES)
}

mod bpf_test_support;

fn setup_mollusk() -> Mollusk {
    let elf_path = bpf_test_support::compile_program("secp_recover_demo");
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

fn instruction_data() -> Vec<u8> {
    let mut data = Vec::with_capacity(32 + 1 + 64);
    data.extend_from_slice(&HASH);
    data.push(RECOVERY_ID);
    data.extend_from_slice(&SIGNATURE);
    data
}

#[test]
fn secp_recover_demo_writes_recovered_pubkey_to_account_zero() {
    let mollusk = setup_mollusk();
    let output_account = Pubkey::new_unique();

    let ix = Instruction {
        program_id: program_id(),
        accounts: vec![AccountMeta::new(output_account, false)],
        data: instruction_data(),
    };

    let result = mollusk.process_instruction(
        &ix,
        &[(
            output_account,
            Account {
                lamports: 1_000_000,
                data: vec![0u8; 64],
                owner: program_id(),
                ..Account::default()
            },
        )],
    );

    assert!(
        !result.program_result.is_err(),
        "secp recover demo should succeed: {:?}",
        result.program_result
    );

    let output = &result.resulting_accounts[0].1.data;
    assert_eq!(&output[0..64], EXPECTED_PUBKEY.as_slice());
}

#[test]
fn secp_recover_demo_rejects_invalid_recovery_id_without_clobbering_output() {
    let mollusk = setup_mollusk();
    let output_account = Pubkey::new_unique();
    let mut invalid_instruction_data = instruction_data();
    invalid_instruction_data[32] = 4;

    let result = mollusk.process_instruction(
        &Instruction {
            program_id: program_id(),
            accounts: vec![AccountMeta::new(output_account, false)],
            data: invalid_instruction_data,
        },
        &[(
            output_account,
            Account {
                lamports: 1_000_000,
                data: vec![0u8; 64],
                owner: program_id(),
                ..Account::default()
            },
        )],
    );

    assert!(
        !result.program_result.is_err(),
        "invalid recovery-id path should still return cleanly: {:?}",
        result.program_result
    );

    let output = &result.resulting_accounts[0].1.data;
    assert_eq!(
        output,
        &vec![0u8; 64],
        "invalid recovery id should leave the output buffer unchanged"
    );
}
