const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Export self as a module
    const solana_mod = b.addModule("solana_program_sdk", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib_unit_tests = b.addTest(.{
        .root_module = solana_mod,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    // -------------------------------------------------------------
    // `zig build examples` — build every `.so` under `examples/`.
    //
    // Requires the solana-zig fork (has `sbf` target). When the host
    // Zig doesn't have it, the step is created but skipped on
    // invocation. This keeps `zig build` (no target) usable on stock
    // Zig for running unit tests.
    // -------------------------------------------------------------
    const examples_step = b.step(
        "examples",
        "Build all example programs (requires solana-zig fork)",
    );
    if (has_sbf_target) {
        const examples = [_][]const u8{
            "hello",
            "counter",
            "vault",
            "escrow",
            "mock_router",
            "mock_adapter",
            "token_dispatch",
            "cpi",
            "pubkey",
        };
        inline for (examples) |name| {
            const ex = buildProgramLocal(b, .{
                .name = name,
                .root_source_file = b.path("examples/" ++ name ++ ".zig"),
                .optimize = .ReleaseFast,
            });
            examples_step.dependOn(ex.step);
        }
    }
}

/// In-tree variant of `buildProgram` that takes the SDK module
/// directly instead of going through `b.dependency` — used by the
/// root `examples` step where the SDK is the *current* package.
/// Downstream consumers should keep using `buildProgram`.
fn buildProgramLocal(
    b: *std.Build,
    options: BuildProgramOptions,
) LinkedProgram {
    const target = b.resolveTargetQuery(sbfTarget());
    const optimize = options.optimize;

    // Create a fresh SDK module against the SBF target. The
    // top-of-`build` `b.addModule` is resolved for the host, so we
    // can't reuse it directly here.
    const sdk_for_sbf = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const program_mod = b.createModule(.{
        .root_source_file = options.root_source_file,
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "solana_program_sdk", .module = sdk_for_sbf },
        },
    });
    program_mod.pic = true;
    program_mod.strip = true;

    const program = b.addLibrary(.{
        .name = options.name,
        .linkage = .dynamic,
        .root_module = program_mod,
    });
    program.entry = .{ .symbol_name = "entrypoint" };
    program.stack_size = 4096;
    program.link_z_notext = true;
    linkSolanaProgram(b, program);

    const so = program.getEmittedBin();
    const install = b.addInstallLibFile(so, b.fmt("{s}.so", .{options.name}));
    b.getInstallStep().dependOn(&install.step);

    return .{
        .name = options.name,
        .module = sdk_for_sbf,
        .so = so,
        .step = &install.step,
    };
}

pub const LinkedProgram = struct {
    name: []const u8,
    module: *std.Build.Module,
    so: std.Build.LazyPath,
    step: *std.Build.Step,
};

pub const has_sbf_target = @hasField(std.Target.Cpu.Arch, "sbf");

pub fn sbfTarget() std.Target.Query {
    return .{
        .cpu_arch = .sbf,
        .os_tag = .solana,
        .cpu_model = .{ .explicit = &std.Target.sbf.cpu.v2 },
    };
}

pub const BuildProgramOptions = struct {
    name: []const u8,
    root_source_file: std.Build.LazyPath,
    optimize: std.builtin.OptimizeMode = .ReleaseFast,
    /// Extra modules to expose to the program in addition to
    /// `solana_program_sdk`. Use this when a program depends on a
    /// monorepo sub-package (e.g. `spl_memo`) — supply
    /// `dep.module("spl_memo")` from the consumer's `build.zig`.
    extra_imports: []const std.Build.Module.Import = &.{},
};

pub fn buildProgram(b: *std.Build, options: BuildProgramOptions) LinkedProgram {
    if (!has_sbf_target) {
        std.log.err("buildProgram requires the solana-zig fork. Download from https://github.com/joncinque/solana-zig-bootstrap/releases", .{});
        std.process.exit(1);
    }
    const target = b.resolveTargetQuery(sbfTarget());
    const optimize = options.optimize;

    const solana_dep = b.dependency("solana_program_sdk", .{
        .target = target,
        .optimize = optimize,
    });
    const solana_mod = solana_dep.module("solana_program_sdk");

    // Concatenate the mandatory SDK import with any caller-supplied
    // extras (sub-packages such as `spl_memo`). The extras' modules
    // must be resolved against the same SBF target — the monorepo's
    // sub-package `build.zig` arranges this via the dependency's
    // shared target/optimize options. Allocations use the build
    // graph's arena so the slice outlives this function.
    const imports = b.allocator.alloc(
        std.Build.Module.Import,
        1 + options.extra_imports.len,
    ) catch @panic("OOM");
    imports[0] = .{ .name = "solana_program_sdk", .module = solana_mod };
    for (options.extra_imports, 0..) |imp, i| imports[i + 1] = imp;

    const program_mod = b.createModule(.{
        .root_source_file = options.root_source_file,
        .target = target,
        .optimize = optimize,
        .imports = imports,
    });
    program_mod.pic = true;
    program_mod.strip = true;

    const program = b.addLibrary(.{
        .name = options.name,
        .linkage = .dynamic,
        .root_module = program_mod,
    });
    program.entry = .{ .symbol_name = "entrypoint" };
    program.stack_size = 4096;
    program.link_z_notext = true;
    linkSolanaProgram(b, program);

    const so = program.getEmittedBin();
    const install = b.addInstallLibFile(so, b.fmt("{s}.so", .{options.name}));
    b.getInstallStep().dependOn(&install.step);

    return .{
        .name = options.name,
        .module = solana_mod,
        .so = so,
        .step = &install.step,
    };
}

pub fn linkSolanaProgram(b: *std.Build, lib: *std.Build.Step.Compile) void {
    const write_file_step = b.addWriteFiles();
    const linker_script = write_file_step.add("bpf.ld",
        \\PHDRS
        \\{
        \\text PT_LOAD  ;
        \\rodata PT_LOAD ;
        \\data PT_LOAD ;
        \\dynamic PT_DYNAMIC ;
        \\}
        \\
        \\SECTIONS
        \\{
        \\. = SIZEOF_HEADERS;
        \\.text : { *(.text*) } :text
        \\.rodata : { *(.rodata*) } :rodata
        \\.data.rel.ro : { *(.data.rel.ro*) } :rodata
        \\.dynamic : { *(.dynamic) } :dynamic
        \\.dynsym : { *(.dynsym) } :data
        \\.dynstr : { *(.dynstr) } :data
        \\.rel.dyn : { *(.rel.dyn) } :data
        \\/DISCARD/ : {
        \\*(.eh_frame*)
        \\*(.gnu.hash*)
        \\*(.hash*)
        \\}
        \\}
    );
    lib.step.dependOn(&write_file_step.step);
    lib.setLinkerScript(linker_script);
}
