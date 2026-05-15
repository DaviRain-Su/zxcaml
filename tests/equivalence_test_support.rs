#![allow(dead_code)]

use mollusk_svm::Mollusk;
use solana_account::Account;
use solana_instruction::{AccountMeta, Instruction};
use solana_pubkey::Pubkey;
use std::{fs, path::Path, path::PathBuf};

use crate::bpf_test_support;

pub const PROGRAM_ID_BYTES: [u8; 32] = [57u8; 32];

pub const HOST_OUTPUT_LEN: usize = 168;
pub const SHA_OFFSET: usize = 0;
pub const KECCAK_OFFSET: usize = 32;
pub const BLAKE3_OFFSET: usize = 64;
pub const HOST_READER_CLOCK_SLOT_OFFSET: usize = 96;
pub const HOST_READER_CLOCK_EPOCH_OFFSET: usize = 104;
pub const HOST_READER_CLOCK_UNIX_OFFSET: usize = 112;
pub const HOST_READER_RENT_LAMPORTS_OFFSET: usize = 120;
pub const HOST_DIRECT_CLOCK_SLOT_OFFSET: usize = 128;
pub const HOST_DIRECT_CLOCK_EPOCH_OFFSET: usize = 136;
pub const HOST_DIRECT_CLOCK_UNIX_OFFSET: usize = 144;
pub const HOST_DIRECT_RENT_LAMPORTS_OFFSET: usize = 152;
pub const HOST_REMAINING_COMPUTE_UNITS_OFFSET: usize = 160;

pub const SYSVAR_OUTPUT_LEN: usize = 72;
pub const SYSVAR_READER_CLOCK_SLOT_OFFSET: usize = 0;
pub const SYSVAR_READER_CLOCK_EPOCH_OFFSET: usize = 8;
pub const SYSVAR_READER_CLOCK_UNIX_OFFSET: usize = 16;
pub const SYSVAR_READER_RENT_LAMPORTS_OFFSET: usize = 24;
pub const SYSVAR_DIRECT_CLOCK_SLOT_OFFSET: usize = 32;
pub const SYSVAR_DIRECT_CLOCK_EPOCH_OFFSET: usize = 40;
pub const SYSVAR_DIRECT_CLOCK_UNIX_OFFSET: usize = 48;
pub const SYSVAR_DIRECT_RENT_LAMPORTS_OFFSET: usize = 56;
pub const SYSVAR_REMAINING_COMPUTE_UNITS_OFFSET: usize = 64;

pub const CLOCK_ACCOUNT_DATA_LEN: usize = 40;
pub const RENT_ACCOUNT_DATA_LEN: usize = 17;

pub const CRYPTO_INPUT: &[u8] = b"m2-syscall-equivalence";
pub const CLOCK_SLOT: u64 = 1_234_567;
pub const CLOCK_EPOCH: u64 = 42;
pub const CLOCK_UNIX_TIMESTAMP: i64 = 1_700_000_123;
pub const RENT_LAMPORTS_PER_BYTE_YEAR: u64 = 3_480;
pub const RENT_EXEMPTION_THRESHOLD_BITS: u64 = 0x4000_0000_0000_0000; // 2.0f64
pub const RENT_BURN_PERCENT: u8 = 50;

pub fn program_id() -> Pubkey {
    Pubkey::new_from_array(PROGRAM_ID_BYTES)
}

pub fn read_u64_le(data: &[u8], offset: usize) -> u64 {
    let mut bytes = [0u8; 8];
    bytes.copy_from_slice(&data[offset..offset + 8]);
    u64::from_le_bytes(bytes)
}

pub fn clock_fixture_bytes() -> Vec<u8> {
    let mut data = vec![0u8; CLOCK_ACCOUNT_DATA_LEN];
    data[0..8].copy_from_slice(&CLOCK_SLOT.to_le_bytes());
    data[8..16].copy_from_slice(&0i64.to_le_bytes());
    data[16..24].copy_from_slice(&CLOCK_EPOCH.to_le_bytes());
    data[24..32].copy_from_slice(&0u64.to_le_bytes());
    data[32..40].copy_from_slice(&CLOCK_UNIX_TIMESTAMP.to_le_bytes());
    data
}

pub fn rent_fixture_bytes() -> Vec<u8> {
    let mut data = vec![0u8; RENT_ACCOUNT_DATA_LEN];
    data[0..8].copy_from_slice(&RENT_LAMPORTS_PER_BYTE_YEAR.to_le_bytes());
    data[8..16].copy_from_slice(&RENT_EXEMPTION_THRESHOLD_BITS.to_le_bytes());
    data[16] = RENT_BURN_PERCENT;
    data
}

pub fn compile_host_runner() -> PathBuf {
    bpf_test_support::compile_host_runner(
        "runtime/zig/syscall_equivalence_host_runner.zig",
        "syscall_equivalence_host_runner",
    )
}

pub fn run_host_runner(host_bin_path: &Path) -> Vec<u8> {
    let result = bpf_test_support::run_binary(host_bin_path);
    let hex = if result.stdout.trim().is_empty() {
        result.stderr.trim()
    } else {
        result.stdout.trim()
    };
    assert!(
        !hex.is_empty(),
        "expected host runner to emit hex output; stdout={:?} stderr={:?}",
        result.stdout,
        result.stderr
    );
    decode_hex(hex)
}

pub fn compile_sysvar_example() -> PathBuf {
    bpf_test_support::compile_program("syscall_equivalence")
}

pub fn run_sysvar_example(elf_path: &Path) -> Vec<u8> {
    let mollusk = setup_mollusk(elf_path);
    let output_account = Pubkey::new_unique();
    let clock_account = Pubkey::new_unique();
    let rent_account = Pubkey::new_unique();

    let ix = Instruction {
        program_id: program_id(),
        accounts: vec![
            AccountMeta::new(output_account, false),
            AccountMeta::new_readonly(clock_account, false),
            AccountMeta::new_readonly(rent_account, false),
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
                    data: vec![0u8; SYSVAR_OUTPUT_LEN],
                    owner: program_id(),
                    ..Account::default()
                },
            ),
            (
                clock_account,
                Account {
                    lamports: 1,
                    data: clock_fixture_bytes(),
                    owner: Pubkey::new_unique(),
                    ..Account::default()
                },
            ),
            (
                rent_account,
                Account {
                    lamports: 1,
                    data: rent_fixture_bytes(),
                    owner: Pubkey::new_unique(),
                    ..Account::default()
                },
            ),
        ],
    );

    assert!(
        !result.program_result.is_err(),
        "syscall equivalence program should succeed: {:?}",
        result.program_result
    );

    result.resulting_accounts[0].1.data.clone()
}

fn setup_mollusk(elf_path: &Path) -> Mollusk {
    let elf = fs::read(elf_path).unwrap_or_else(|error| {
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
    mollusk.sysvars.clock.slot = CLOCK_SLOT;
    mollusk.sysvars.clock.epoch = CLOCK_EPOCH;
    mollusk.sysvars.clock.unix_timestamp = CLOCK_UNIX_TIMESTAMP;
    #[allow(deprecated)]
    {
        mollusk.sysvars.rent.lamports_per_byte_year = RENT_LAMPORTS_PER_BYTE_YEAR;
    }
    mollusk
}

fn decode_hex(hex: &str) -> Vec<u8> {
    assert_eq!(
        hex.len() % 2,
        0,
        "hex output must contain an even number of characters: {hex}"
    );

    let mut out = Vec::with_capacity(hex.len() / 2);
    let bytes = hex.as_bytes();
    let mut index = 0usize;
    while index < bytes.len() {
        let pair = std::str::from_utf8(&bytes[index..index + 2])
            .unwrap_or_else(|error| panic!("invalid UTF-8 in hex output at {index}: {error}"));
        let byte = u8::from_str_radix(pair, 16)
            .unwrap_or_else(|error| panic!("invalid hex byte `{pair}` at {index}: {error}"));
        out.push(byte);
        index += 2;
    }
    out
}
