//! SVM-level integration test for the ZxCaml token_vault program.
//!
//! The setup step compiles `examples/token_vault.ml` to
//! `build/token_vault.so` with the local `omlz` binary, then verifies
//! initialize, deposit, and withdraw against mocked SPL Token mint/account
//! state using the zignocchio-compatible instruction discriminators.

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

const PROGRAM_ID_BYTES: [u8; 32] = [19u8; 32];
const TOKEN_ACCOUNT_LEN: usize = 165;
const MINT_LEN: usize = 82;
const VAULT_RENT_LAMPORTS: u64 = 2_039_280;
const SYSTEM_PROGRAM_ID: Pubkey = solana_pubkey::pubkey!("11111111111111111111111111111111");
const TOKEN_PROGRAM_ID: Pubkey =
    solana_pubkey::pubkey!("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA");
const RENT_SYSVAR_ID: Pubkey = solana_pubkey::pubkey!("SysvarRent111111111111111111111111111111111");
const NATIVE_LOADER_ID: Pubkey =
    solana_pubkey::pubkey!("NativeLoader1111111111111111111111111111111");

fn program_id() -> Pubkey {
    Pubkey::new_from_array(PROGRAM_ID_BYTES)
}

fn vault_pda_for_owner(owner: &Pubkey) -> (Pubkey, u8) {
    let (pda, bump) = Pubkey::find_program_address(&[b"vault", owner.as_ref()], &program_id());
    let recreated =
        Pubkey::create_program_address(&[b"vault", owner.as_ref(), &[bump]], &program_id())
            .expect("find_program_address must return a valid bump seed");
    assert_eq!(pda, recreated, "test fixture should use canonical PDA");
    (pda, bump)
}

fn owner_with_vault_pda_bump_255() -> (Pubkey, Pubkey, u8) {
    loop {
        let owner = Pubkey::new_unique();
        let (vault, bump) = vault_pda_for_owner(&owner);
        if bump == 255 {
            return (owner, vault, bump);
        }
    }
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
    let elf_path = compile_program("token_vault");
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
        .program_cache
        .add_builtin(mollusk_svm::program::Builtin {
            program_id: SYSTEM_PROGRAM_ID,
            name: "system_program",
            entrypoint: solana_system_program::system_processor::Entrypoint::vm,
        });
    mollusk
}

fn system_account() -> Account {
    Account {
        executable: true,
        owner: NATIVE_LOADER_ID,
        ..Account::default()
    }
}

fn token_program_account() -> Account {
    Account {
        executable: true,
        owner: NATIVE_LOADER_ID,
        ..Account::default()
    }
}

fn rent_sysvar_account() -> Account {
    Account {
        lamports: 1,
        owner: SYSTEM_PROGRAM_ID,
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

fn deposit_data(amount: u64) -> Vec<u8> {
    let mut data = vec![0];
    data.extend_from_slice(&amount.to_le_bytes());
    data
}

#[test]
fn token_vault_test_initialize_deposit_withdraws_mocked_spl_tokens() {
    let mollusk = setup_mollusk();
    let (owner, vault, _bump) = owner_with_vault_pda_bump_255();
    let mint = Pubkey::new_unique();
    let user_token = Pubkey::new_unique();
    let initial_owner_lamports = 10_000_000u64;
    let initial_user_tokens = 500u64;
    let deposit_amount = 125u64;

    let init_ix = Instruction {
        program_id: program_id(),
        accounts: vec![
            AccountMeta::new(vault, false),
            AccountMeta::new_readonly(mint, false),
            AccountMeta::new_readonly(owner, true),
            AccountMeta::new_readonly(SYSTEM_PROGRAM_ID, false),
            AccountMeta::new_readonly(TOKEN_PROGRAM_ID, false),
            AccountMeta::new_readonly(RENT_SYSVAR_ID, false),
        ],
        data: vec![2],
    };

    let owner_account = Account {
        lamports: initial_owner_lamports,
        owner: SYSTEM_PROGRAM_ID,
        ..Account::default()
    };
    let vault_account = Account {
        lamports: VAULT_RENT_LAMPORTS,
        data: vec![0; TOKEN_ACCOUNT_LEN],
        owner: program_id(),
        ..Account::default()
    };
    let mint_account = Account {
        lamports: 1,
        data: vec![0; MINT_LEN],
        owner: TOKEN_PROGRAM_ID,
        ..Account::default()
    };

    let init_result = mollusk.process_instruction(
        &init_ix,
        &[
            (vault, vault_account),
            (mint, mint_account),
            (owner, owner_account),
            (SYSTEM_PROGRAM_ID, system_account()),
            (TOKEN_PROGRAM_ID, token_program_account()),
            (RENT_SYSVAR_ID, rent_sysvar_account()),
        ],
    );

    assert!(
        !init_result.program_result.is_err(),
        "token_vault initialize should succeed: {:?}",
        init_result.program_result
    );
    let vault_after_init = &init_result.resulting_accounts[0].1;
    let owner_after_init = &init_result.resulting_accounts[2].1;
    assert_eq!(vault_after_init.owner, program_id());
    assert_eq!(vault_after_init.lamports, VAULT_RENT_LAMPORTS);
    assert_eq!(owner_after_init.lamports, initial_owner_lamports);
    assert_eq!(&vault_after_init.data[0..32], mint.as_ref());
    assert_eq!(&vault_after_init.data[32..64], vault.as_ref());
    assert_eq!(token_amount(&vault_after_init.data), 0);

    let user_token_account = Account {
        lamports: 1,
        data: token_account_data(&mint, &owner, initial_user_tokens),
        owner: program_id(),
        ..Account::default()
    };

    let deposit_ix = Instruction {
        program_id: program_id(),
        accounts: vec![
            AccountMeta::new(user_token, false),
            AccountMeta::new(vault, false),
            AccountMeta::new_readonly(owner, true),
            AccountMeta::new_readonly(TOKEN_PROGRAM_ID, false),
            AccountMeta::new_readonly(SYSTEM_PROGRAM_ID, false),
            AccountMeta::new_readonly(RENT_SYSVAR_ID, false),
        ],
        data: deposit_data(deposit_amount),
    };

    let deposit_result = mollusk.process_instruction(
        &deposit_ix,
        &[
            (user_token, user_token_account),
            (vault, vault_after_init.clone()),
            (owner, owner_after_init.clone()),
            (
                TOKEN_PROGRAM_ID,
                init_result.resulting_accounts[4].1.clone(),
            ),
            (
                SYSTEM_PROGRAM_ID,
                init_result.resulting_accounts[3].1.clone(),
            ),
            (RENT_SYSVAR_ID, init_result.resulting_accounts[5].1.clone()),
        ],
    );

    assert!(
        !deposit_result.program_result.is_err(),
        "token_vault deposit should succeed: {:?}",
        deposit_result.program_result
    );
    let user_after_deposit = &deposit_result.resulting_accounts[0].1;
    let vault_after_deposit = &deposit_result.resulting_accounts[1].1;
    assert_eq!(
        token_amount(&user_after_deposit.data),
        initial_user_tokens - deposit_amount
    );
    assert_eq!(token_amount(&vault_after_deposit.data), deposit_amount);

    let withdraw_ix = Instruction {
        program_id: program_id(),
        accounts: vec![
            AccountMeta::new(vault, false),
            AccountMeta::new(user_token, false),
            AccountMeta::new_readonly(owner, true),
            AccountMeta::new_readonly(TOKEN_PROGRAM_ID, false),
            AccountMeta::new_readonly(SYSTEM_PROGRAM_ID, false),
            AccountMeta::new_readonly(RENT_SYSVAR_ID, false),
        ],
        data: vec![1],
    };

    let withdraw_result = mollusk.process_instruction(
        &withdraw_ix,
        &[
            (vault, vault_after_deposit.clone()),
            (user_token, user_after_deposit.clone()),
            (owner, deposit_result.resulting_accounts[2].1.clone()),
            (
                TOKEN_PROGRAM_ID,
                deposit_result.resulting_accounts[3].1.clone(),
            ),
            (
                SYSTEM_PROGRAM_ID,
                deposit_result.resulting_accounts[4].1.clone(),
            ),
            (RENT_SYSVAR_ID, deposit_result.resulting_accounts[5].1.clone()),
        ],
    );

    assert!(
        !withdraw_result.program_result.is_err(),
        "token_vault withdraw should succeed: {:?}",
        withdraw_result.program_result
    );
    let vault_after_withdraw = &withdraw_result.resulting_accounts[0].1;
    let user_after_withdraw = &withdraw_result.resulting_accounts[1].1;
    assert_eq!(token_amount(&vault_after_withdraw.data), 0);
    assert_eq!(token_amount(&user_after_withdraw.data), initial_user_tokens);
}
