#![allow(dead_code)]

use std::{
    ffi::OsString,
    fs::{self, OpenOptions},
    path::{Path, PathBuf},
    process::Command,
    thread,
    time::Duration,
};

use agave_feature_set;
use mollusk_svm::{program::ProgramCache, Mollusk};

/// Build a mollusk runtime instance that keeps SBPF version support within
/// the range supported by the current test environment.
pub fn new_mollusk() -> Mollusk {
    let mut mollusk = Mollusk::default();

    let mut feature_set = mollusk.feature_set.clone();
    feature_set.deactivate(&agave_feature_set::enable_sbpf_v3_deployment_and_execution::id());
    feature_set.deactivate(&agave_feature_set::disable_sbpf_v0_execution::id());

    let program_cache = ProgramCache::new(&feature_set, &mollusk.compute_budget, false);

    mollusk.feature_set = feature_set;
    mollusk.program_cache = program_cache;

    mollusk
}

pub struct BuildLock {
    path: PathBuf,
}

impl Drop for BuildLock {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}

pub fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("tests/ must live under the repository root")
        .to_path_buf()
}

pub fn acquire_build_lock(root: &Path) -> BuildLock {
    let build_dir = root.join("build");
    fs::create_dir_all(&build_dir).expect("failed to create build/ output directory");
    let path = build_dir.join(".omlz-build.lock");

    for _ in 0..600 {
        match OpenOptions::new().write(true).create_new(true).open(&path) {
            Ok(_) => return BuildLock { path },
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                thread::sleep(Duration::from_millis(100));
            }
            Err(error) => {
                panic!("failed to create build lock at {}: {error}", path.display())
            }
        }
    }

    panic!("timed out waiting for build lock at {}", path.display());
}

pub fn llvm_lib_dir() -> Option<PathBuf> {
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

pub fn apply_platform_env(command: &mut Command) {
    if !cfg!(target_os = "macos") {
        return;
    }

    if !std::env::var("SOLANA_ZIG").is_ok_and(|value| value == "0") {
        return;
    }

    if let Some(lib) = llvm_lib_dir() {
        let mut value = OsString::from(lib);
        if let Some(existing) = std::env::var_os("DYLD_FALLBACK_LIBRARY_PATH") {
            value.push(":");
            value.push(existing);
        }
        command.env("DYLD_FALLBACK_LIBRARY_PATH", value);
    }
}

pub fn compile_program_from_path(source_path: &Path, output_path: &Path) -> PathBuf {
    let root = repo_root();
    let _lock = acquire_build_lock(&root);
    compile_program_from_path_locked(&root, source_path, output_path)
}

fn compile_program_from_path_locked(root: &Path, source_path: &Path, output_path: &Path) -> PathBuf {
    let mut command = Command::new(root.join("zig-out").join("bin").join("omlz"));
    command.current_dir(&root).args([
        "build",
        "--target=bpf",
        source_path
            .to_str()
            .expect("source path must be UTF-8 to pass to olmz command"),
        "-o",
        output_path
            .to_str()
            .expect("output path must be UTF-8 to pass to omlz command"),
    ]);
    apply_platform_env(&mut command);

    let result = command.output().unwrap_or_else(|error| {
        panic!(
            "failed to spawn `zig-out/bin/omlz build --target=bpf {} -o {}`: {error}",
            source_path.display(),
            output_path.display()
        )
    });
    assert!(
        result.status.success(),
        "`zig-out/bin/omlz build --target=bpf {} -o {}` failed\nstderr:\n{}",
        source_path.display(),
        output_path.display(),
        String::from_utf8_lossy(&result.stderr)
    );
    assert!(
        output_path.exists(),
        "expected BPF artifact at {}",
        output_path.display()
    );

    output_path.to_path_buf()
}

pub fn compile_program(example: &str) -> PathBuf {
    let root = repo_root();
    let source_path = root.join("examples").join(format!("{example}.ml"));
    let output_path = root.join("build").join(format!("{example}.so"));
    compile_program_from_path(&source_path, &output_path)
}

pub fn compile_program_and_host_runner(
    example: &str,
    host_runner_relative_path: &str,
    host_bin_name: &str,
) -> (PathBuf, PathBuf) {
    let root = repo_root();
    let _lock = acquire_build_lock(&root);

    let source_path = root.join("examples").join(format!("{example}.ml"));
    let elf_path = root.join("build").join(format!("{example}.so"));
    let elf_path = compile_program_from_path_locked(&root, &source_path, &elf_path);

    let host_runner_path = root.join(host_runner_relative_path);
    let host_bin_path = root.join("build").join(host_bin_name);
    compile_host_runner_locked(&root, &host_runner_path, &host_bin_path);

    (elf_path, host_bin_path)
}

pub fn compile_host_runner(host_runner_relative_path: &str, host_bin_name: &str) -> PathBuf {
    let root = repo_root();
    let _lock = acquire_build_lock(&root);
    let host_runner_path = root.join(host_runner_relative_path);
    let host_bin_path = root.join("build").join(host_bin_name);
    compile_host_runner_locked(&root, &host_runner_path, &host_bin_path);
    host_bin_path
}

fn compile_host_runner_locked(root: &Path, runner_path: &Path, output_path: &Path) {
    let root_module_arg = format!("-Mroot={}", runner_path.display());
    let vendored_sdk_arg = format!("-Mvendored_sdk={}", root.join("runtime/zig/sdk/root.zig").display());
    let solana_sdk_m2_arg = format!(
        "-Msolana_sdk_m2={}",
        root.join("vendor/solana-program-sdk-zig/src/zxcaml_m2_root.zig")
            .display()
    );
    let runtime_syscalls_arg = format!("-Mruntime_syscalls={}", root.join("runtime/zig/syscalls.zig").display());
    let runtime_sysvar_arg = format!("-Mruntime_sysvar={}", root.join("runtime/zig/sysvar.zig").display());
    let emit_bin_arg = format!("-femit-bin={}", output_path.display());

    let mut command = Command::new("zig");
    command.current_dir(root);
    command.args([
        "build-exe",
        "-O",
        "ReleaseSmall",
        "--dep",
        "vendored_sdk",
        "--dep",
        "solana_sdk_m2",
        "--dep",
        "runtime_syscalls",
        "--dep",
        "runtime_sysvar",
        root_module_arg.as_str(),
        vendored_sdk_arg.as_str(),
        solana_sdk_m2_arg.as_str(),
        runtime_syscalls_arg.as_str(),
        runtime_sysvar_arg.as_str(),
        emit_bin_arg.as_str(),
    ]);
    apply_platform_env(&mut command);

    let result = command.output().unwrap_or_else(|error| {
        panic!(
            "failed to spawn `zig build-exe` for host runner {} -> {}: {error}",
            runner_path.display(),
            output_path.display()
        )
    });
    assert!(
        result.status.success(),
        "`zig build-exe` for host runner {} -> {} failed\nstdout:\n{}\nstderr:\n{}",
        runner_path.display(),
        output_path.display(),
        String::from_utf8_lossy(&result.stdout),
        String::from_utf8_lossy(&result.stderr)
    );
    assert!(
        output_path.exists(),
        "expected host runner artifact at {}",
        output_path.display()
    );
}

pub struct CompiledProgram {
    pub elf_path: PathBuf,
    pub generated_source: String,
}

pub fn compile_program_with_source(example: &str) -> CompiledProgram {
    let output_path = compile_program(example);
    let root = repo_root();
    let generated_path = root.join("out").join("program.zig");
    let generated_source = fs::read_to_string(&generated_path).unwrap_or_else(|error| {
        panic!(
            "failed to read generated Zig source at {}: {error}",
            generated_path.display()
        )
    });

    CompiledProgram {
        elf_path: output_path,
        generated_source,
    }
}

pub struct BinaryOutput {
    pub status: std::process::ExitStatus,
    pub stdout: String,
    pub stderr: String,
}

pub fn run_binary(path: &Path) -> BinaryOutput {
    let root = repo_root();
    let result = Command::new(path)
        .current_dir(&root)
        .output()
        .unwrap_or_else(|error| panic!("failed to run {}: {error}", path.display()));

    assert!(
        result.status.success(),
        "expected {} to succeed\nstdout:\n{}\nstderr:\n{}",
        path.display(),
        String::from_utf8_lossy(&result.stdout),
        String::from_utf8_lossy(&result.stderr)
    );

    BinaryOutput {
        status: result.status,
        stdout: String::from_utf8_lossy(&result.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&result.stderr).into_owned(),
    }
}
