//! SVM-level integration test for the ZxCaml escrow_full program.
//!
//! The setup step compiles `examples/escrow_full.ml` to
//! `build/escrow_full.so` with the local `omlz` binary, then verifies the
//! zignocchio-compatible make, accept, and refund instruction flows.
//!
//! The zignocchio escrow source creates a PDA account through System Program
//! CPI. The current ZxCaml Mollusk fixture preallocates the canonical
//! bump-255 PDA account as program-owned data, then the runtime helper mutates
//! lamports and the zignocchio `EscrowState` byte layout directly. This mirrors
//! the mocked-account convention used by token_vault for CPI-heavy examples.

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

#[path = "src/srcmap.rs"]
mod srcmap;

const PROGRAM_ID_BYTES: [u8; 32] = [20u8; 32];
const ESCROW_DISCRIMINATOR: u8 = 0xE5;
const ESCROW_STATE_LEN: usize = 80;
const ESCROW_AMOUNT_OFFSET: usize = 72;
const ESCROW_RENT_LAMPORTS: u64 = 6_960;
const SYSTEM_PROGRAM_ID: Pubkey = solana_pubkey::pubkey!("11111111111111111111111111111111");
const NATIVE_LOADER_ID: Pubkey =
    solana_pubkey::pubkey!("NativeLoader1111111111111111111111111111111");

fn program_id() -> Pubkey {
    Pubkey::new_from_array(PROGRAM_ID_BYTES)
}

fn escrow_pda_for_maker(maker: &Pubkey) -> (Pubkey, u8) {
    let (pda, bump) = Pubkey::find_program_address(&[b"escrow", maker.as_ref()], &program_id());
    let recreated =
        Pubkey::create_program_address(&[b"escrow", maker.as_ref(), &[bump]], &program_id())
            .expect("find_program_address must return a valid bump seed");
    assert_eq!(pda, recreated, "test fixture should use canonical PDA");
    (pda, bump)
}

fn maker_with_escrow_pda_bump_255() -> (Pubkey, Pubkey, u8) {
    loop {
        let maker = Pubkey::new_unique();
        let (escrow, bump) = escrow_pda_for_maker(&maker);
        if bump == 255 {
            return (maker, escrow, bump);
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
    let llvm_roots = ["/opt/homebrew/opt", "/usr/local/opt"];
    for root in llvm_roots {
        if let Ok(entries) = fs::read_dir(root) {
            for entry in entries.flatten() {
                let name = entry.file_name();
                let name = name.to_string_lossy();
                if !name.starts_with("llvm") {
                    continue;
                }

                let candidate = entry.path().join("lib");
                if candidate.join("libLLVM.dylib").exists() {
                    return Some(candidate);
                }
            }
        }
    }

    None
}


fn llvm_objdump_path() -> PathBuf {
    let llvm_roots = ["/opt/homebrew/opt", "/usr/local/opt"];
    for root in llvm_roots {
        if let Ok(entries) = fs::read_dir(root) {
            for entry in entries.flatten() {
                let name = entry.file_name();
                let name = name.to_string_lossy();
                if !name.starts_with("llvm") {
                    continue;
                }

                let candidate = entry.path().join("bin").join("llvm-objdump");
                if candidate.exists() {
                    return candidate;
                }
            }
        }
    }

    PathBuf::from("llvm-objdump")
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

fn assert_embedded_srcmap_section(elf_path: &Path) {
    let mut command = Command::new(llvm_objdump_path());
    command.args(["-h"]).arg(elf_path);
    apply_platform_env(&mut command);

    let output = match command.output() {
        Ok(output) => output,
        Err(error) => {
            if error.kind() == std::io::ErrorKind::NotFound {
                return;
            }
            panic!(
                "failed to spawn `llvm-objdump -h {}` while checking embedded source map: {error}",
                elf_path.display()
            )
        }
    };

    if !output.status.success() {
        panic!(
            "`llvm-objdump -h {}` failed\nstdout:\n{}\nstderr:\n{}",
            elf_path.display(),
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let section_line = stdout.lines().find(|line| line.contains(".zxcaml.srcmap"));
    let section_line = match section_line {
        Some(line) => line,
        None => return,
    };

    // mission-internal/p9-investigation/report.md §4 found loader risk low
    // because llvm-objcopy adds this as a non-allocated SHT_PROGBITS section.
    // Keep that safety property live while Mollusk loads the augmented escrow ELF.
    assert!(
        !section_line.contains("ALLOC"),
        "expected .zxcaml.srcmap to remain non-allocated, got section line: {section_line}"
    );
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
    assert_embedded_srcmap_section(&output_path);
    output_path
}

fn setup_mollusk_with_elf() -> (Mollusk, PathBuf) {
    let elf_path = compile_program("escrow_full");
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
    (mollusk, elf_path)
}

fn setup_mollusk() -> Mollusk {
    let (mollusk, _elf_path) = setup_mollusk_with_elf();
    mollusk
}

#[test]
fn escrow_full_test_srcmap_augmented_so_loads_in_mollusk() {
    let (_mollusk, elf_path) = setup_mollusk_with_elf();
    srcmap::assert_with_unmap_on_failure(
        &elf_path,
        "0x0",
        std::env::var_os("ZXCAML_FORCE_UNMAP_DEMO").is_none(),
        "forced escrow_full source-map unmap demo failure",
    );
}

fn system_account() -> Account {
    Account {
        executable: true,
        owner: NATIVE_LOADER_ID,
        ..Account::default()
    }
}

fn escrow_account() -> Account {
    Account {
        lamports: 0,
        data: vec![0; ESCROW_STATE_LEN],
        owner: program_id(),
        ..Account::default()
    }
}

fn make_data(taker: &Pubkey, amount: u64) -> Vec<u8> {
    let mut data = vec![0];
    data.extend_from_slice(taker.as_ref());
    data.extend_from_slice(&amount.to_le_bytes());
    data
}

fn escrow_amount(data: &[u8]) -> u64 {
    let mut amount = [0u8; 8];
    amount.copy_from_slice(&data[ESCROW_AMOUNT_OFFSET..ESCROW_AMOUNT_OFFSET + 8]);
    u64::from_le_bytes(amount)
}

fn assert_escrow_state(data: &[u8], maker: &Pubkey, taker: &Pubkey, amount: u64) {
    assert_eq!(data[0], ESCROW_DISCRIMINATOR);
    assert_eq!(&data[1..33], maker.as_ref());
    assert_eq!(&data[33..65], taker.as_ref());
    assert_eq!(escrow_amount(data), amount);
}

#[test]
fn escrow_full_test_make_and_accept_transfers_escrow_lamports() {
    let mollusk = setup_mollusk();
    let (maker, escrow, _bump) = maker_with_escrow_pda_bump_255();
    let taker = Pubkey::new_unique();
    let initial_maker_lamports = 1_000_000u64;
    let initial_taker_lamports = 7_000u64;
    let amount = 50_000u64;
    let escrow_total = amount + ESCROW_RENT_LAMPORTS;

    let make_ix = Instruction {
        program_id: program_id(),
        accounts: vec![
            AccountMeta::new(maker, true),
            AccountMeta::new(escrow, false),
            AccountMeta::new_readonly(SYSTEM_PROGRAM_ID, false),
        ],
        data: make_data(&taker, amount),
    };

    let maker_account = Account {
        lamports: initial_maker_lamports,
        owner: SYSTEM_PROGRAM_ID,
        ..Account::default()
    };

    let make_result = mollusk.process_instruction(
        &make_ix,
        &[
            (maker, maker_account),
            (escrow, escrow_account()),
            (SYSTEM_PROGRAM_ID, system_account()),
        ],
    );

    assert!(
        !make_result.program_result.is_err(),
        "escrow_full make should succeed: {:?}",
        make_result.program_result
    );
    let maker_after_make = &make_result.resulting_accounts[0].1;
    let escrow_after_make = &make_result.resulting_accounts[1].1;
    assert_eq!(
        maker_after_make.lamports,
        initial_maker_lamports - escrow_total
    );
    assert_eq!(escrow_after_make.lamports, escrow_total);
    assert_escrow_state(&escrow_after_make.data, &maker, &taker, amount);

    let accept_ix = Instruction {
        program_id: program_id(),
        accounts: vec![
            AccountMeta::new(taker, true),
            AccountMeta::new(escrow, false),
            AccountMeta::new_readonly(maker, false),
        ],
        data: vec![1],
    };
    let taker_account = Account {
        lamports: initial_taker_lamports,
        owner: SYSTEM_PROGRAM_ID,
        ..Account::default()
    };

    let accept_result = mollusk.process_instruction(
        &accept_ix,
        &[
            (taker, taker_account),
            (escrow, escrow_after_make.clone()),
            (maker, maker_after_make.clone()),
        ],
    );

    assert!(
        !accept_result.program_result.is_err(),
        "escrow_full accept should succeed: {:?}",
        accept_result.program_result
    );
    let taker_after_accept = &accept_result.resulting_accounts[0].1;
    let escrow_after_accept = &accept_result.resulting_accounts[1].1;
    assert_eq!(
        taker_after_accept.lamports,
        initial_taker_lamports + escrow_total
    );
    assert_eq!(escrow_after_accept.lamports, 0);
    assert_eq!(escrow_after_accept.data[0], 0);
}

#[test]
fn escrow_full_test_make_and_refund_returns_lamports_to_maker() {
    let mollusk = setup_mollusk();
    let (maker, escrow, _bump) = maker_with_escrow_pda_bump_255();
    let taker = Pubkey::new_unique();
    let initial_maker_lamports = 2_000_000u64;
    let amount = 90_000u64;
    let escrow_total = amount + ESCROW_RENT_LAMPORTS;

    let make_ix = Instruction {
        program_id: program_id(),
        accounts: vec![
            AccountMeta::new(maker, true),
            AccountMeta::new(escrow, false),
            AccountMeta::new_readonly(SYSTEM_PROGRAM_ID, false),
        ],
        data: make_data(&taker, amount),
    };
    let maker_account = Account {
        lamports: initial_maker_lamports,
        owner: SYSTEM_PROGRAM_ID,
        ..Account::default()
    };
    let make_result = mollusk.process_instruction(
        &make_ix,
        &[
            (maker, maker_account),
            (escrow, escrow_account()),
            (SYSTEM_PROGRAM_ID, system_account()),
        ],
    );

    assert!(
        !make_result.program_result.is_err(),
        "escrow_full make before refund should succeed: {:?}",
        make_result.program_result
    );
    let maker_after_make = &make_result.resulting_accounts[0].1;
    let escrow_after_make = &make_result.resulting_accounts[1].1;
    assert_eq!(
        maker_after_make.lamports,
        initial_maker_lamports - escrow_total
    );
    assert_eq!(escrow_after_make.lamports, escrow_total);
    assert_escrow_state(&escrow_after_make.data, &maker, &taker, amount);

    let refund_ix = Instruction {
        program_id: program_id(),
        accounts: vec![
            AccountMeta::new(maker, true),
            AccountMeta::new(escrow, false),
        ],
        data: vec![2],
    };
    let refund_result = mollusk.process_instruction(
        &refund_ix,
        &[
            (maker, maker_after_make.clone()),
            (escrow, escrow_after_make.clone()),
        ],
    );

    assert!(
        !refund_result.program_result.is_err(),
        "escrow_full refund should succeed: {:?}",
        refund_result.program_result
    );
    let maker_after_refund = &refund_result.resulting_accounts[0].1;
    let escrow_after_refund = &refund_result.resulting_accounts[1].1;
    assert_eq!(maker_after_refund.lamports, initial_maker_lamports);
    assert_eq!(escrow_after_refund.lamports, 0);
    assert_eq!(escrow_after_refund.data[0], 0);
}
