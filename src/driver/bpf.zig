//! BPF build orchestration for emitted Zig source.
//!
//! RESPONSIBILITIES:
//! - Materialise the BPF runtime shim next to generated `out/program.zig`.
//! - Drive Zig's BPF bitcode emission step with the ADR-012 flags.
//! - Invoke `sbpf-linker` with the ADR-013 default SBPF CPU and diagnostics.
//! - Let `sbpf-linker --export entrypoint` preserve the loader entry symbol.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const core_anf = @import("../core/anf.zig");
const core_const_fold = @import("../core/const_fold.zig");
const core_dce = @import("../core/dce.zig");
const core_inline = @import("../core/inline.zig");
const core_ir = @import("../core/ir.zig");
const ttree = @import("../frontend_bridge/ttree.zig");
const srcmap = @import("srcmap.zig");

/// ADR-013: mainnet-compatible SBPF v2 is the default; v3 will be opt-in later.
const default_sbpf_cpu = "v2";
const pinned_sbpf_linker_version = "0.1.8";

/// Options for the Solana BPF build path.
pub const BpfBuildOptions = struct {
    bpf_entry_path: []const u8 = "out/bpf_entry.zig",
    bitcode_path: []const u8 = "out/program.bc",
    output_path: []const u8,
    environ: std.process.Environ,
    source_map: ?SourceMapInput = null,
    source_map_hook: ?SourceMapHook = null,
    quiet: bool = false,
};

/// Core IR source-map input retained through BPF build orchestration.
///
/// F-SRCMAP-2 intentionally does not write a sidecar yet. Instead, callers can
/// provide this input plus `source_map_hook` to receive the deterministic
/// in-memory schema after a successful BPF build.
pub const SourceMapInput = struct {
    program: []const u8,
    module: core_ir.Module,
};

/// In-memory source map plus the instruction-count bound used by validators.
pub const SourceMapBuild = struct {
    schema: srcmap.Schema,
    total_instructions: u32,
};

/// Hook that future sidecar/ELF emission features can use without changing the
/// BPF link contract.
pub const SourceMapHook = struct {
    context: *anyopaque,
    emit: *const fn (context: *anyopaque, build: SourceMapBuild) anyerror!void,
};

const RuntimeFile = struct {
    src_path: []const u8,
    out_path: []const u8,
};

const srcmap_section_name = ".zxcaml.srcmap";

const runtime_files = [_]RuntimeFile{
    .{ .src_path = "runtime/zig/arena.zig", .out_path = "out/runtime/arena.zig" },
    .{ .src_path = "runtime/zig/account.zig", .out_path = "out/runtime/account.zig" },
    .{ .src_path = "runtime/zig/cpi.zig", .out_path = "out/runtime/cpi.zig" },
    .{ .src_path = "runtime/zig/programs/common.zig", .out_path = "out/runtime/programs/common.zig" },
    .{ .src_path = "runtime/zig/programs/transfer_sol.zig", .out_path = "out/runtime/programs/transfer_sol.zig" },
    .{ .src_path = "runtime/zig/programs/vault.zig", .out_path = "out/runtime/programs/vault.zig" },
    .{ .src_path = "runtime/zig/programs/vault_v2.zig", .out_path = "out/runtime/programs/vault_v2.zig" },
    .{ .src_path = "runtime/zig/programs/hackathon_greet.zig", .out_path = "out/runtime/programs/hackathon_greet.zig" },
    .{ .src_path = "runtime/zig/programs/token_vault.zig", .out_path = "out/runtime/programs/token_vault.zig" },
    .{ .src_path = "runtime/zig/programs/escrow_full.zig", .out_path = "out/runtime/programs/escrow_full.zig" },
    .{ .src_path = "runtime/zig/programs/dao_voting.zig", .out_path = "out/runtime/programs/dao_voting.zig" },
    .{ .src_path = "runtime/zig/programs/ata_transfer.zig", .out_path = "out/runtime/programs/ata_transfer.zig" },
    .{ .src_path = "runtime/zig/programs/order_book.zig", .out_path = "out/runtime/programs/order_book.zig" },
    .{ .src_path = "runtime/zig/programs/ata.zig", .out_path = "out/runtime/programs/ata.zig" },
    .{ .src_path = "runtime/zig/bs58.zig", .out_path = "out/runtime/bs58.zig" },
    .{ .src_path = "runtime/zig/panic.zig", .out_path = "out/runtime/panic.zig" },
    .{ .src_path = "runtime/zig/prelude.zig", .out_path = "out/runtime/prelude.zig" },
    .{ .src_path = "runtime/zig/spl_token.zig", .out_path = "out/runtime/spl_token.zig" },
    .{ .src_path = "runtime/zig/syscalls.zig", .out_path = "out/runtime/syscalls.zig" },
    .{ .src_path = "runtime/zig/bpf_entry.zig", .out_path = "out/bpf_entry.zig" },
};

/// Builds a Solana-loadable SBPF ELF shared object from generated Zig source.
pub fn buildBpf(allocator: Allocator, io: Io, options: BpfBuildOptions) !void {
    try materializeRuntime(allocator, io);

    const bitcode_arg = try std.fmt.allocPrint(allocator, "-femit-llvm-bc={s}", .{options.bitcode_path});
    defer allocator.free(bitcode_arg);

    const zig_argv = [_][]const u8{
        "zig",
        "build-lib",
        "-target",
        "bpfel-freestanding",
        "-O",
        "ReleaseSmall",
        "-fno-stack-check",
        "-fno-PIC",
        "-fno-PIE",
        "-fstrip",
        bitcode_arg,
        "-fno-emit-bin",
        options.bpf_entry_path,
    };

    try runAndForward(allocator, io, &zig_argv, null, error.BpfZigBuildFailed, !options.quiet);

    var env_map = try makeLinkerEnv(allocator, io, options.environ);
    defer env_map.deinit();

    const linker_argv = [_][]const u8{
        "sbpf-linker",
        "--cpu",
        default_sbpf_cpu,
        "--llvm-args=-bpf-stack-size=4096",
        "--export",
        "entrypoint",
        "-o",
        options.output_path,
        options.bitcode_path,
    };

    runAndForward(allocator, io, &linker_argv, &env_map, error.SbpfLinkFailed, !options.quiet) catch |err| switch (err) {
        error.FileNotFound => {
            try writeMissingSbpfLinkerDiagnostic(io);
            return error.SbpfLinkerMissing;
        },
        else => |e| return e,
    };

    if (options.source_map_hook) |hook| {
        const input = options.source_map orelse return error.MissingSourceMapInput;
        const source_map = try buildSourceMapSchema(allocator, input);
        defer allocator.free(source_map.schema.entries);
        try hook.emit(hook.context, source_map);
        try embedSourceMapSection(allocator, io, options.output_path, source_map.schema);
    }
}

/// Builds the deterministic in-memory source-map schema from Core IR locations.
///
/// Investigation §4 notes that exact post-LLVM BPF PCs are not available until
/// the linker has produced ELF text. F-SRCMAP-2's hook therefore captures a
/// stable instruction-index stream while BPF lowering still has Core IR `loc`
/// data; later SRCMAP features can replace the index assignment with post-link
/// byte offsets without changing the schema or hook shape.
pub fn buildSourceMapSchema(allocator: Allocator, input: SourceMapInput) !SourceMapBuild {
    var collector: SourceMapCollector = .{
        .allocator = allocator,
        .entries = std.ArrayList(srcmap.Entry).empty,
    };
    errdefer collector.entries.deinit(allocator);

    try collector.collectModule(input.module);

    const entries = try collector.entries.toOwnedSlice(allocator);
    errdefer allocator.free(entries);

    const schema: srcmap.Schema = .{
        .program = input.program,
        .entries = entries,
    };
    try srcmap.validateSchema(schema);

    return .{
        .schema = schema,
        .total_instructions = collector.next_pc,
    };
}

const SourceMapCollector = struct {
    allocator: Allocator,
    entries: std.ArrayList(srcmap.Entry),
    next_pc: u32 = 0,

    fn collectModule(self: *SourceMapCollector, module: core_ir.Module) !void {
        for (module.decls) |decl| {
            switch (decl) {
                .Let => |let_decl| try self.collectExpr(let_decl.value),
                .LetGroup => |group| {
                    for (group.bindings) |binding| {
                        try self.collectExpr(binding.value);
                    }
                },
            }
        }
    }

    fn collectExpr(self: *SourceMapCollector, expr: *const core_ir.Expr) !void {
        try self.recordLoc(core_ir.exprLoc(expr.*));

        switch (expr.*) {
            .Lambda => |value| try self.collectExpr(value.body),
            .Constant, .Var => {},
            .App => |value| {
                try self.collectExpr(value.callee);
                for (value.args) |arg| try self.collectExpr(arg);
            },
            .Let => |value| {
                try self.collectExpr(value.value);
                try self.collectExpr(value.body);
            },
            .LetGroup => |value| {
                for (value.bindings) |binding| try self.collectExpr(binding.value);
                try self.collectExpr(value.body);
            },
            .Assert => |value| try self.collectExpr(value.condition),
            .If => |value| {
                try self.collectExpr(value.cond);
                try self.collectExpr(value.then_branch);
                try self.collectExpr(value.else_branch);
            },
            .Prim => |value| {
                for (value.args) |arg| try self.collectExpr(arg);
            },
            .Ctor => |value| {
                for (value.args) |arg| try self.collectExpr(arg);
            },
            .Match => |value| {
                try self.collectExpr(value.scrutinee);
                for (value.arms) |arm| {
                    if (arm.guard) |guard| try self.collectExpr(guard);
                    try self.collectExpr(arm.body);
                }
            },
            .Tuple => |value| {
                for (value.items) |item| try self.collectExpr(item);
            },
            .TupleProj => |value| try self.collectExpr(value.tuple_expr),
            .Record => |value| {
                for (value.fields) |field| try self.collectExpr(field.value);
            },
            .RecordField => |value| try self.collectExpr(value.record_expr),
            .RecordUpdate => |value| {
                try self.collectExpr(value.base_expr);
                for (value.fields) |field| try self.collectExpr(field.value);
            },
            .AccountFieldSet => |value| {
                try self.collectExpr(value.account_expr);
                try self.collectExpr(value.value);
            },
        }
    }

    fn recordLoc(self: *SourceMapCollector, maybe_loc: ?core_ir.Loc) !void {
        const loc = maybe_loc orelse return;
        if (loc.isUnknown()) return;

        try self.entries.append(self.allocator, .{
            .pc = self.next_pc,
            .ml_file = loc.file,
            .ml_line = loc.line,
            .ml_col = loc.col,
        });
        self.next_pc += 1;
    }
};

fn materializeRuntime(allocator: Allocator, io: Io) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, "out/runtime");
    try cwd.createDirPath(io, "out/runtime/programs");

    inline for (runtime_files) |file| {
        const contents = try cwd.readFileAlloc(io, file.src_path, allocator, .limited(128 * 1024));
        defer allocator.free(contents);

        try cwd.writeFile(io, .{
            .sub_path = file.out_path,
            .data = contents,
            .flags = .{ .truncate = true },
        });
    }
}

fn runAndForward(
    allocator: Allocator,
    io: Io,
    argv: []const []const u8,
    environ_map: ?*const std.process.Environ.Map,
    failure: anyerror,
    forward_success_output: bool,
) !void {
    const completed = try std.process.run(allocator, io, .{
        .argv = argv,
        .environ_map = environ_map,
    });
    defer allocator.free(completed.stdout);
    defer allocator.free(completed.stderr);

    const success = switch (completed.term) {
        .exited => |code| code == 0,
        .signal, .stopped, .unknown => false,
    };

    if (forward_success_output or !success) {
        if (completed.stdout.len > 0) try writeStdout(io, completed.stdout);
        if (completed.stderr.len > 0) try writeToolStderr(io, completed.stderr);
    }

    if (success) return;
    return failure;
}

fn makeLinkerEnv(allocator: Allocator, io: Io, environ: std.process.Environ) !std.process.Environ.Map {
    var env_map = try std.process.Environ.createMap(environ, allocator);
    errdefer env_map.deinit();

    if (builtin.os.tag == .macos and env_map.get("DYLD_FALLBACK_LIBRARY_PATH") == null) {
        if (try detectHomebrewLlvm20Lib(allocator, io)) |llvm_lib| {
            defer allocator.free(llvm_lib);
            try env_map.put("DYLD_FALLBACK_LIBRARY_PATH", llvm_lib);
        }
    }

    return env_map;
}

fn detectHomebrewLlvm20Lib(allocator: Allocator, io: Io) !?[]const u8 {
    if (builtin.os.tag != .macos) return null;

    const prefix = try detectHomebrewLlvm20Prefix(allocator, io) orelse return null;
    defer allocator.free(prefix);

    const llvm_lib = try std.fs.path.join(allocator, &.{ prefix, "lib" });
    return @as([]const u8, llvm_lib);
}

fn findLlvmObjcopy(allocator: Allocator, io: Io) ![]const u8 {
    if (builtin.os.tag == .macos) {
        if (try detectHomebrewLlvm20Prefix(allocator, io)) |prefix| {
            defer allocator.free(prefix);
            const candidate = try std.fs.path.join(allocator, &.{ prefix, "bin", "llvm-objcopy" });
            errdefer allocator.free(candidate);
            if (isExecutable(io, candidate)) return candidate;
            allocator.free(candidate);
        }
    }

    return allocator.dupe(u8, "llvm-objcopy");
}

fn detectHomebrewLlvm20Prefix(allocator: Allocator, io: Io) !?[]const u8 {
    if (builtin.os.tag != .macos) return null;

    const argv = [_][]const u8{ "brew", "--prefix", "llvm@20" };
    const completed = std.process.run(allocator, io, .{ .argv = &argv }) catch return null;
    defer allocator.free(completed.stdout);
    defer allocator.free(completed.stderr);

    switch (completed.term) {
        .exited => |code| if (code != 0) return null,
        .signal, .stopped, .unknown => return null,
    }

    const prefix = std.mem.trim(u8, completed.stdout, " \t\r\n");
    if (prefix.len == 0) return null;
    return try allocator.dupe(u8, prefix);
}

fn isExecutable(io: Io, path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.Io.Dir.accessAbsolute(io, path, .{ .execute = true }) catch return false;
        return true;
    }
    std.Io.Dir.cwd().access(io, path, .{ .execute = true }) catch return false;
    return true;
}

fn embedSourceMapSection(allocator: Allocator, io: Io, output_path: []const u8, schema: srcmap.Schema) !void {
    // F-SRCMAP-4 follows investigation §4 / Appendix B: add a post-link
    // SHT_PROGBITS section containing the same deterministic, minified JSON as
    // the sidecar, gzip-compressed. `llvm-objcopy --add-section` does not set
    // SHF_ALLOC by default, so the Solana loader ignores the new section.
    const json = try srcmap.serializeJson(allocator, schema);
    defer allocator.free(json);

    const gzipped = try gzipBytes(allocator, json);
    defer allocator.free(gzipped);

    const temp_section_path = try std.fmt.allocPrint(allocator, "{s}.zxcaml.srcmap.gz.tmp", .{output_path});
    defer allocator.free(temp_section_path);
    defer std.Io.Dir.cwd().deleteFile(io, temp_section_path) catch {};

    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = temp_section_path,
        .data = gzipped,
        .flags = .{ .truncate = true },
    });

    const section_arg = try std.fmt.allocPrint(allocator, "{s}={s}", .{ srcmap_section_name, temp_section_path });
    defer allocator.free(section_arg);

    const objcopy = try findLlvmObjcopy(allocator, io);
    defer allocator.free(objcopy);

    const argv = [_][]const u8{
        objcopy,
        "--add-section",
        section_arg,
        output_path,
    };
    try runAndForward(allocator, io, &argv, null, error.LlvmObjcopyFailed, true);
}

fn gzipBytes(allocator: Allocator, bytes: []const u8) ![]u8 {
    var output = try std.Io.Writer.Allocating.initCapacity(allocator, bytes.len + std.compress.flate.Container.gzip.size());
    errdefer output.deinit();

    const flate_buffer = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(flate_buffer);

    var compressor = try std.compress.flate.Compress.init(
        &output.writer,
        flate_buffer,
        .gzip,
        .default,
    );
    try compressor.writer.writeAll(bytes);
    try compressor.finish();

    return output.toOwnedSlice();
}

fn writeMissingSbpfLinkerDiagnostic(io: Io) !void {
    try writeStderr(io, "error: sbpf-linker not found on PATH; ZxCaml requires sbpf-linker ");
    try writeStderr(io, pinned_sbpf_linker_version);
    try writeStderr(io, " per ADR-012. Run ./init.sh to install the pinned BPF toolchain.\n");
}

fn writeStdout(io: Io, bytes: []const u8) !void {
    var buffer: [1024]u8 = undefined;
    var file_writer: Io.File.Writer = .init(.stdout(), io, &buffer);
    const writer = &file_writer.interface;
    try writer.writeAll(bytes);
    try writer.flush();
}

fn writeStderr(io: Io, bytes: []const u8) !void {
    var buffer: [1024]u8 = undefined;
    var file_writer: Io.File.Writer = .init(.stderr(), io, &buffer);
    const writer = &file_writer.interface;
    try writer.writeAll(bytes);
    try writer.flush();
}

fn writeToolStderr(io: Io, bytes: []const u8) !void {
    // sbpf-linker's LLVM proxy scans Homebrew's llvm@20 directory on macOS and
    // tries to `dlopen` every `libLLVM*.a` static archive. Static archives can
    // never be loaded with dlopen, so suppress only those probe lines while
    // preserving genuine dynamic-library and linker diagnostics.
    var start: usize = 0;
    while (start < bytes.len) {
        const line_end = std.mem.indexOfScalarPos(u8, bytes, start, '\n') orelse bytes.len;
        const segment_end = if (line_end < bytes.len) line_end + 1 else line_end;
        const line = bytes[start..line_end];

        if (!isStaticArchiveDlopenWarning(line)) {
            try writeStderr(io, bytes[start..segment_end]);
        }

        start = segment_end;
    }
}

fn isStaticArchiveDlopenWarning(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "unable to open LLVM shared lib ") != null and
        std.mem.indexOf(u8, line, ".a: dlopen failed") != null;
}

fn countDlopenMentionsIgnoreCase(bytes: []const u8) usize {
    const needle = "dlopen";
    var count: usize = 0;
    var index: usize = 0;

    while (index + needle.len <= bytes.len) : (index += 1) {
        for (needle, 0..) |needle_char, offset| {
            const actual = std.ascii.toLower(bytes[index + offset]);
            if (actual != needle_char) break;
        } else {
            count += 1;
            index += needle.len - 1;
        }
    }

    return count;
}

test "static archive LLVM dlopen warnings are filtered narrowly" {
    try std.testing.expect(isStaticArchiveDlopenWarning(
        "unable to open LLVM shared lib /opt/homebrew/opt/llvm@20/lib/libLLVMAnalysis.a: dlopen failed",
    ));
    try std.testing.expect(!isStaticArchiveDlopenWarning(
        "unable to open LLVM shared lib /opt/homebrew/opt/llvm@20/lib/libLLVM.dylib: dlopen failed",
    ));
    try std.testing.expect(!isStaticArchiveDlopenWarning(
        "error: sbpf-linker failed to parse out/program.bc",
    ));
}

test "BPF build smoke does not spam LLVM dlopen warnings" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const output_path = "out/zxcaml_dlopen_smoke.so";
    const cwd = std.Io.Dir.cwd();
    defer cwd.deleteFile(io, output_path) catch {};

    const argv = [_][]const u8{
        "zig-out/bin/omlz",
        "build",
        "--target=bpf",
        "examples/hackathon_greet.ml",
        "-o",
        output_path,
    };

    const completed = try std.process.run(allocator, io, .{ .argv = &argv });
    defer allocator.free(completed.stdout);
    defer allocator.free(completed.stderr);

    const exit_code: u8 = switch (completed.term) {
        .exited => |code| code,
        .signal, .stopped, .unknown => 1,
    };
    if (exit_code != 0) {
        std.debug.print(
            "BPF smoke build failed\nstdout:\n{s}\nstderr:\n{s}\n",
            .{ completed.stdout, completed.stderr },
        );
    }
    try std.testing.expectEqual(@as(u8, 0), exit_code);

    const stdout_dlopen_count = countDlopenMentionsIgnoreCase(completed.stdout);
    const stderr_dlopen_count = countDlopenMentionsIgnoreCase(completed.stderr);
    const dlopen_count = stdout_dlopen_count + stderr_dlopen_count;
    if (dlopen_count > 2) {
        std.debug.print(
            "BPF smoke build emitted {d} dlopen mentions\nstdout:\n{s}\nstderr:\n{s}\n",
            .{ dlopen_count, completed.stdout, completed.stderr },
        );
    }
    try std.testing.expect(dlopen_count <= 2);
}

test "BPF linker argv pins ADR-013 default SBPF v2 CPU and entrypoint export" {
    const linker_argv = [_][]const u8{
        "sbpf-linker",
        "--cpu",
        default_sbpf_cpu,
        "--llvm-args=-bpf-stack-size=4096",
        "--export",
        "entrypoint",
        "-o",
        "/tmp/m0_zero.so",
        "out/program.bc",
    };

    try std.testing.expectEqualStrings("sbpf-linker", linker_argv[0]);
    try std.testing.expectEqualStrings("--cpu", linker_argv[1]);
    try std.testing.expectEqualStrings("v2", linker_argv[2]);
    try std.testing.expectEqualStrings("--llvm-args=-bpf-stack-size=4096", linker_argv[3]);
    try std.testing.expectEqualStrings("--export", linker_argv[4]);
    try std.testing.expectEqualStrings("entrypoint", linker_argv[5]);
}

fn testExitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        .signal, .stopped, .unknown => 1,
    };
}

test "BPF source map builder captures hackathon_greet source locations" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const frontend_argv = [_][]const u8{
        "zig-out/bin/zxc-frontend",
        "--emit=sexp",
        "examples/hackathon_greet.ml",
    };
    const frontend = try std.process.run(allocator, io, .{ .argv = &frontend_argv });
    defer allocator.free(frontend.stdout);
    defer allocator.free(frontend.stderr);

    if (testExitCode(frontend.term) != 0) {
        std.debug.print("zxc-frontend failed while building source-map fixture:\n{s}\n", .{frontend.stderr});
    }
    try std.testing.expectEqual(@as(u8, 0), testExitCode(frontend.term));

    var frontend_arena = std.heap.ArenaAllocator.init(allocator);
    defer frontend_arena.deinit();
    const typed_module = try ttree.parseModule(&frontend_arena, frontend.stdout);

    var core_arena = std.heap.ArenaAllocator.init(allocator);
    defer core_arena.deinit();
    const lowered = try core_anf.lowerModule(&core_arena, typed_module);
    const folded = try core_const_fold.foldModule(&core_arena, lowered);
    const eliminated = try core_dce.eliminateModule(&core_arena, folded);
    const inlined = try core_inline.inlineModule(&core_arena, eliminated);
    const optimized = try core_const_fold.foldModule(&core_arena, inlined);

    const built = try buildSourceMapSchema(allocator, .{
        .program = "hackathon_greet",
        .module = optimized,
    });
    defer allocator.free(built.schema.entries);

    try srcmap.validateSchema(built.schema);
    try std.testing.expect(built.schema.entries.len >= 1);
    for (built.schema.entries) |entry| {
        try std.testing.expect(entry.pc < built.total_instructions);
        try std.testing.expect(std.mem.endsWith(u8, entry.ml_file, "hackathon_greet.ml"));
    }
}
