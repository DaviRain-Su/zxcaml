//! SVM-level integration test for the ZxCaml ata_transfer program.
//!
//! The setup step compiles `examples/ata_transfer.ml` to
//! `build/ata_transfer.so` with the local `omlz` binary.  This test follows
//! the program-owned mocked SPL Token account fixture convention: source and
//! destination token accounts are owned by the example program, not Tokenkeg,
//! and the BPF helper mutates the packed SPL Token `amount` field directly.

use mollusk_svm::Mollusk;
use solana_account::Account;
use solana_instruction::{AccountMeta, Instruction};
use solana_pubkey::Pubkey;
use std::{
    ffi::OsString,
    fs::{self, OpenOptions},
    path::{Path, PathBuf},
    process::Command,
    thread,
    time::Duration,
};

const PROGRAM_ID_BYTES: [u8; 32] = [22u8; 32];
const TOKEN_ACCOUNT_LEN: usize = 165;
const MINT_LEN: usize = 82;
const ATA_LAMPORTS: u64 = 2_039_280;
const SYSTEM_PROGRAM_ID: Pubkey = solana_pubkey::pubkey!("11111111111111111111111111111111");
const TOKEN_PROGRAM_ID: Pubkey =
    solana_pubkey::pubkey!("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA");
const NATIVE_LOADER_ID: Pubkey =
    solana_pubkey::pubkey!("NativeLoader1111111111111111111111111111111");

fn program_id() -> Pubkey {
    Pubkey::new_from_array(PROGRAM_ID_BYTES)
}

struct BuildLock {
    path: PathBuf,
}

impl Drop for BuildLock {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("tests/ must live under the repository root")
        .to_path_buf()
}

fn acquire_build_lock(root: &Path) -> BuildLock {
    let build_dir = root.join("build");
    fs::create_dir_all(&build_dir).expect("failed to create build/ output directory");
    let path = build_dir.join(".omlz-build.lock");

    for _ in 0..600 {
        match OpenOptions::new().write(true).create_new(true).open(&path) {
            Ok(_) => return BuildLock { path },
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                thread::sleep(Duration::from_millis(100));
            }
            Err(error) => panic!("failed to create build lock at {}: {error}", path.display()),
        }
    }

    panic!("timed out waiting for build lock at {}", path.display());
}

fn llvm20_lib_dir() -> Option<PathBuf> {
    for candidate in [
        PathBuf::from("/opt/homebrew/opt/llvm@20/lib"),
        PathBuf::from("/usr/local/opt/llvm@20/lib"),
    ] {
        if candidate.join("libLLVM.dylib").exists() {
            return Some(candidate);
        }
    }

    let output = Command::new("brew")
        .args(["--prefix", "llvm@20"])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }

    let prefix = String::from_utf8(output.stdout).ok()?;
    let lib = PathBuf::from(prefix.trim()).join("lib");
    lib.join("libLLVM.dylib").exists().then_some(lib)
}

fn apply_platform_env(command: &mut Command) {
    if cfg!(target_os = "macos") {
        if let Some(lib) = llvm20_lib_dir() {
            let mut value = OsString::from(lib);
            if let Some(existing) = std::env::var_os("DYLD_FALLBACK_LIBRARY_PATH") {
                value.push(":");
                value.push(existing);
            }
            command.env("DYLD_FALLBACK_LIBRARY_PATH", value);
        }
    }
}

fn compile_program(example: &str) -> PathBuf {
    let root = repo_root();
    let _lock = acquire_build_lock(&root);
    let output_path = root.join("build").join(format!("{example}.so"));
    let source = format!("examples/{example}.ml");
    let output = format!("build/{example}.so");

    let mut command = Command::new(root.join("zig-out").join("bin").join("omlz"));
    command.current_dir(&root).args([
        "build",
        "--target=bpf",
        source.as_str(),
        "-o",
        output.as_str(),
    ]);
    apply_platform_env(&mut command);

    let result = command.output().unwrap_or_else(|error| {
        panic!(
            "failed to spawn `zig-out/bin/omlz build --target=bpf {source} -o {output}`: {error}"
        )
    });
    assert!(
        result.status.success(),
        "`zig-out/bin/omlz build --target=bpf {source} -o {output}` failed\nstdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&result.stdout),
        String::from_utf8_lossy(&result.stderr)
    );
    assert!(
        output_path.exists(),
        "expected BPF artifact at {}",
        output_path.display()
    );
    output_path
}

fn setup_mollusk() -> Mollusk {
    let elf_path = compile_program("ata_transfer");
    let elf = fs::read(&elf_path).unwrap_or_else(|error| {
        panic!(
            "failed to read sBPF artifact at {}: {}",
            elf_path.display(),
            error
        )
    });
    let pid = program_id();
    let loader_v3 = solana_pubkey::pubkey!("BPFLoaderUpgradeab1e11111111111111111111111");
    let mut mollusk = Mollusk::default();
    mollusk.add_program_with_loader_and_elf(&pid, &loader_v3, &elf);
    mollusk
}

fn executable_program_account() -> Account {
    Account {
        executable: true,
        owner: NATIVE_LOADER_ID,
        ..Account::default()
    }
}

fn signer_account(lamports: u64) -> Account {
    Account {
        lamports,
        ..Account::default()
    }
}

fn mint_account() -> Account {
    Account {
        lamports: 1,
        data: vec![0; MINT_LEN],
        owner: TOKEN_PROGRAM_ID,
        ..Account::default()
    }
}

fn empty_mock_token_account() -> Account {
    Account {
        lamports: ATA_LAMPORTS,
        data: vec![0; TOKEN_ACCOUNT_LEN],
        owner: program_id(),
        ..Account::default()
    }
}

fn token_account_data(mint: &Pubkey, owner: &Pubkey, amount: u64) -> Vec<u8> {
    let mut data = vec![0u8; TOKEN_ACCOUNT_LEN];
    data[0..32].copy_from_slice(mint.as_ref());
    data[32..64].copy_from_slice(owner.as_ref());
    data[64..72].copy_from_slice(&amount.to_le_bytes());
    data[108] = 1;
    data
}

fn token_amount(data: &[u8]) -> u64 {
    let mut amount = [0u8; 8];
    amount.copy_from_slice(&data[64..72]);
    u64::from_le_bytes(amount)
}

fn transfer_data(amount: u64) -> Vec<u8> {
    let mut data = vec![0x01];
    data.extend_from_slice(&amount.to_le_bytes());
    data
}

#[test]
fn ata_transfer_initializes_destination_ata_then_transfers_mocked_tokens() {
    let mollusk = setup_mollusk();
    let funding = Pubkey::new_unique();
    let destination_ata = Pubkey::new_unique();
    let destination_owner = Pubkey::new_unique();
    let mint = Pubkey::new_unique();

    let initialize_ix = Instruction {
        program_id: program_id(),
        accounts: vec![
            AccountMeta::new(funding, true),
            AccountMeta::new(destination_ata, false),
            AccountMeta::new_readonly(destination_owner, false),
            AccountMeta::new_readonly(mint, false),
            AccountMeta::new_readonly(SYSTEM_PROGRAM_ID, false),
            AccountMeta::new_readonly(TOKEN_PROGRAM_ID, false),
        ],
        data: vec![0x00],
    };

    let initialize_result = mollusk.process_instruction(
        &initialize_ix,
        &[
            (funding, signer_account(10_000_000)),
            (destination_ata, empty_mock_token_account()),
            (destination_owner, signer_account(1)),
            (mint, mint_account()),
            (SYSTEM_PROGRAM_ID, executable_program_account()),
            (TOKEN_PROGRAM_ID, executable_program_account()),
        ],
    );
    assert!(
        !initialize_result.program_result.is_err(),
        "ata_transfer initialize should succeed: {:?}",
        initialize_result.program_result
    );

    let destination_after_initialize = &initialize_result.resulting_accounts[1].1;
    assert_eq!(destination_after_initialize.owner, program_id());
    assert_eq!(&destination_after_initialize.data[0..32], mint.as_ref());
    assert_eq!(
        &destination_after_initialize.data[32..64],
        destination_owner.as_ref()
    );
    assert_eq!(token_amount(&destination_after_initialize.data), 0);
    assert_eq!(destination_after_initialize.data[108], 1);

    let source_ata = Pubkey::new_unique();
    let authority = Pubkey::new_unique();
    let initial_source_amount = 500u64;
    let transfer_amount = 125u64;
    let source_account = Account {
        lamports: ATA_LAMPORTS,
        data: token_account_data(&mint, &authority, initial_source_amount),
        owner: program_id(),
        ..Account::default()
    };

    let transfer_ix = Instruction {
        program_id: program_id(),
        accounts: vec![
            AccountMeta::new(source_ata, false),
            AccountMeta::new(destination_ata, false),
            AccountMeta::new_readonly(authority, true),
            AccountMeta::new_readonly(mint, false),
            AccountMeta::new_readonly(SYSTEM_PROGRAM_ID, false),
            AccountMeta::new_readonly(TOKEN_PROGRAM_ID, false),
        ],
        data: transfer_data(transfer_amount),
    };

    let transfer_result = mollusk.process_instruction(
        &transfer_ix,
        &[
            (source_ata, source_account),
            (destination_ata, destination_after_initialize.clone()),
            (authority, signer_account(1)),
            (mint, mint_account()),
            (SYSTEM_PROGRAM_ID, executable_program_account()),
            (TOKEN_PROGRAM_ID, executable_program_account()),
        ],
    );
    assert!(
        !transfer_result.program_result.is_err(),
        "ata_transfer transfer should succeed: {:?}",
        transfer_result.program_result
    );

    let source_after_transfer = &transfer_result.resulting_accounts[0].1;
    let destination_after_transfer = &transfer_result.resulting_accounts[1].1;
    assert_eq!(
        token_amount(&source_after_transfer.data),
        initial_source_amount - transfer_amount
    );
    assert_eq!(
        token_amount(&destination_after_transfer.data),
        transfer_amount
    );
    assert_eq!(&destination_after_transfer.data[0..32], mint.as_ref());
    assert_eq!(
        &destination_after_transfer.data[32..64],
        destination_owner.as_ref()
    );
}
