//! SVM-level integration test for the ZxCaml StakeHistory/EpochSchedule demo.
//!
//! The setup step compiles `examples/stake_epoch_demo.ml` to
//! `build/stake_epoch_demo.so`. The test passes deterministic serialized
//! StakeHistory and EpochSchedule sysvar account bytes, then asserts account 0
//! receives newest_epoch + newest_effective + slots_per_epoch as a u64.

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

const PROGRAM_ID_BYTES: [u8; 32] = [52u8; 32];
const EXPECTED_NEWEST_EPOCH: u64 = 11;
const EXPECTED_NEWEST_EFFECTIVE: u64 = 210;
const EXPECTED_SLOTS_PER_EPOCH: u64 = 432_000;
const EXPECTED_SUM: u64 =
    EXPECTED_NEWEST_EPOCH + EXPECTED_NEWEST_EFFECTIVE + EXPECTED_SLOTS_PER_EPOCH;

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
    let elf_path = compile_program("stake_epoch_demo");
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

fn append_u64(out: &mut Vec<u8>, value: u64) {
    out.extend_from_slice(&value.to_le_bytes());
}

fn stake_history_data() -> Vec<u8> {
    let mut data = Vec::with_capacity(8 + (2 * 32));
    append_u64(&mut data, 2);
    append_u64(&mut data, 10);
    append_u64(&mut data, 100);
    append_u64(&mut data, 1);
    append_u64(&mut data, 2);
    append_u64(&mut data, EXPECTED_NEWEST_EPOCH);
    append_u64(&mut data, EXPECTED_NEWEST_EFFECTIVE);
    append_u64(&mut data, 3);
    append_u64(&mut data, 4);
    data
}

fn epoch_schedule_data() -> Vec<u8> {
    let mut data = vec![0u8; 33];
    data[0..8].copy_from_slice(&EXPECTED_SLOTS_PER_EPOCH.to_le_bytes());
    data
}

fn read_u64_le(data: &[u8], offset: usize) -> u64 {
    let mut bytes = [0u8; 8];
    bytes.copy_from_slice(&data[offset..offset + 8]);
    u64::from_le_bytes(bytes)
}

#[test]
fn stake_epoch_demo_sums_latest_stake_history_and_slots_per_epoch() {
    let mollusk = setup_mollusk();
    let output_account = Pubkey::new_unique();
    let stake_history_account =
        solana_pubkey::pubkey!("SysvarStakeHistory1111111111111111111111111");
    let epoch_schedule_account =
        solana_pubkey::pubkey!("SysvarEpochSchedu1e111111111111111111111111");

    let ix = Instruction {
        program_id: program_id(),
        accounts: vec![
            AccountMeta::new(output_account, false),
            AccountMeta::new_readonly(stake_history_account, false),
            AccountMeta::new_readonly(epoch_schedule_account, false),
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
                    data: vec![0u8; 8],
                    owner: program_id(),
                    ..Account::default()
                },
            ),
            (
                stake_history_account,
                Account {
                    lamports: 1,
                    data: stake_history_data(),
                    ..Account::default()
                },
            ),
            (
                epoch_schedule_account,
                Account {
                    lamports: 1,
                    data: epoch_schedule_data(),
                    ..Account::default()
                },
            ),
        ],
    );

    assert!(
        !result.program_result.is_err(),
        "stake/epoch demo should succeed: {:?}",
        result.program_result
    );

    let output = &result.resulting_accounts[0].1.data;
    assert_eq!(read_u64_le(output, 0), EXPECTED_SUM);
}
