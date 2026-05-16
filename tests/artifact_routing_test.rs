use std::fs;

mod bpf_test_support;

#[test]
fn generated_validation_artifacts_stay_under_ignored_paths() {
    let root = bpf_test_support::repo_root();
    let zig_characterization = fs::read_to_string(root.join("tests/cli/bpf_build_contract_test.zig"))
        .expect("failed to read Zig characterization test source");

    assert!(
        zig_characterization.contains(".zig-cache/characterization-tests"),
        "expected Zig characterization outputs to live under .zig-cache"
    );
    assert!(
        !zig_characterization.contains("build/characterization-tests"),
        "expected Zig characterization outputs to stop using build/characterization-tests"
    );

    let host_runner_path = bpf_test_support::host_runner_output_path("syscall_equivalence_host_runner");
    assert!(
        host_runner_path.starts_with(root.join("tests").join("target")),
        "expected host runner output under tests/target, got {}",
        host_runner_path.display()
    );
    assert!(
        !host_runner_path.starts_with(root.join("build")),
        "expected host runner output to avoid build/, got {}",
        host_runner_path.display()
    );
}
