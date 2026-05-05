//! Helpers for surfacing OCaml source locations from Mollusk assertion failures.

use std::{
    path::{Path, PathBuf},
    process::Command,
};

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("tests/ must live under the repository root")
        .to_path_buf()
}

/// If `condition` is false, run `omlz unmap --so <so_path> --pc <pc_hex>`,
/// print the source-map answer to stderr, then panic with `message`.
pub fn assert_with_unmap_on_failure(so_path: &Path, pc_hex: &str, condition: bool, message: &str) {
    if condition {
        return;
    }

    print_unmap(so_path, pc_hex);
    panic!("{message}");
}

fn print_unmap(so_path: &Path, pc_hex: &str) {
    let root = repo_root();
    let output = Command::new(root.join("zig-out").join("bin").join("omlz"))
        .current_dir(&root)
        .args(["unmap", "--so"])
        .arg(so_path)
        .args(["--pc", pc_hex])
        .output();

    let output = match output {
        Ok(output) => output,
        Err(error) => {
            eprintln!(
                "srcmap helper: failed to spawn `omlz unmap --so {} --pc {pc_hex}`: {error}",
                so_path.display()
            );
            return;
        }
    };

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    if output.status.success() {
        let answer = stdout.trim();
        if answer.is_empty() {
            eprintln!(
                "srcmap helper: `omlz unmap --so {} --pc {pc_hex}` succeeded but printed no source location",
                so_path.display()
            );
        } else {
            eprintln!("{answer}");
        }
    } else {
        eprintln!(
            "srcmap helper: `omlz unmap --so {} --pc {pc_hex}` failed with status {}\nstdout:\n{}\nstderr:\n{}",
            so_path.display(),
            output.status,
            stdout,
            stderr
        );
    }
}
