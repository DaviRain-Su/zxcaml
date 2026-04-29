//! SVM-level integration test for the Crypto stdlib wrappers.
//!
//! The setup step compiles `examples/crypto_demo.ml` to `build/crypto_demo.so`
//! with the local `omlz` binary, then loads that artifact into Mollusk and
//! verifies the SHA-256 and Keccak-256 digests logged through `sol_log_pubkey`.

use mollusk_svm::Mollusk;
use solana_instruction::Instruction;
use solana_pubkey::Pubkey;
use solana_svm_log_collector::LogCollector;
use std::{
    ffi::OsString,
    fs::{self, OpenOptions},
    path::{Path, PathBuf},
    process::Command,
    thread,
    time::Duration,
};

const PROGRAM_ID_BYTES: [u8; 32] = [7u8; 32];
const HASH_INPUT: &[u8] = b"zxcaml crypto demo";

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
    let elf_path = compile_program("crypto_demo");
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

#[test]
fn test_crypto_demo_executes_successfully_and_logs_expected_hashes() {
    let mut mollusk = setup_mollusk();
    let log_collector = LogCollector::new_ref();
    mollusk.logger = Some(log_collector.clone());

    let ix = Instruction {
        program_id: program_id(),
        accounts: vec![],
        data: HASH_INPUT.to_vec(),
    };

    let result = mollusk.process_instruction(&ix, &[]);
    assert!(
        !result.program_result.is_err(),
        "crypto demo should succeed: {:?}",
        result.program_result
    );

    let expected_sha =
        Pubkey::new_from_array(solana_sha256_hasher::hash(HASH_INPUT).to_bytes()).to_string();
    let expected_keccak =
        Pubkey::new_from_array(solana_keccak_hasher::hash(HASH_INPUT).to_bytes()).to_string();

    assert_ne!(
        expected_sha, expected_keccak,
        "SHA-256 and Keccak-256 should produce different digests for the demo input"
    );

    let logs = log_collector.borrow();
    let messages = logs.get_recorded_content();
    assert!(
        messages
            .iter()
            .any(|message| message.contains("crypto demo sha256")),
        "crypto demo should label the SHA-256 digest; captured logs: {messages:?}"
    );
    assert!(
        messages
            .iter()
            .any(|message| message.contains(expected_sha.as_str())),
        "crypto demo should log expected SHA-256 pubkey {expected_sha}; captured logs: {messages:?}"
    );
    assert!(
        messages
            .iter()
            .any(|message| message.contains("crypto demo keccak256")),
        "crypto demo should label the Keccak-256 digest; captured logs: {messages:?}"
    );
    assert!(
        messages
            .iter()
            .any(|message| message.contains(expected_keccak.as_str())),
        "crypto demo should log expected Keccak-256 pubkey {expected_keccak}; captured logs: {messages:?}"
    );
}
