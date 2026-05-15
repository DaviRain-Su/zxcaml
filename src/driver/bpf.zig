//! BPF build orchestration for emitted Zig source.
//!
//! RESPONSIBILITIES:
//! - Materialise the BPF runtime shim next to generated `out/program.zig`.
//! - Invoke `solana-zig build-lib` in the canonical direct path.

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
const target_manifest = @import("../target/manifest.zig");
const srcmap = @import("srcmap.zig");

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

const srcmap_section_name = ".zxcaml.srcmap";
const vendored_sdk_runtime_root = "out/runtime/sdk/root.zig";
const vendored_solana_program_sdk_root = "vendor/solana-program-sdk-zig/src/root.zig";
const vendored_solana_codec_root = "vendor/solana-program-sdk-zig/packages/solana-codec/src/root.zig";
const vendored_spl_token_root = "vendor/solana-program-sdk-zig/packages/spl-token/src/root.zig";
const vendored_spl_ata_root = "vendor/solana-program-sdk-zig/packages/spl-ata/src/root.zig";
const vendored_solana_system_root = "vendor/solana-program-sdk-zig/packages/solana-system/src/root.zig";
const vendored_spl_memo_root = "vendor/solana-program-sdk-zig/packages/spl-memo/src/root.zig";

/// Builds a Solana-loadable SBPF ELF shared object from generated Zig source.
///
/// Uses the one-step direct `solana-zig build-lib` pipeline.
pub fn buildBpf(allocator: Allocator, io: Io, options: BpfBuildOptions) !void {
    try target_manifest.materializeRuntimeForDispatch(allocator, io, .bpf);

    try buildBpfDirect(allocator, io, options);

    if (options.source_map_hook) |hook| {
        const input = options.source_map orelse return error.MissingSourceMapInput;
        const source_map = try buildSourceMapSchema(allocator, input);
        defer allocator.free(source_map.schema.entries);
        try hook.emit(hook.context, source_map);
        // Track per-build whether we already warned about missing
        // `llvm-objcopy` so the non-fatal degradation message is emitted at
        // most once per BPF compile invocation.
        var warned_missing_objcopy: bool = false;
        try embedSourceMapSection(allocator, io, options.output_path, source_map.schema, &warned_missing_objcopy);
    }
}

/// One-step BPF build using `solana-zig`.
pub fn buildBpfDirect(allocator: Allocator, io: Io, options: BpfBuildOptions) !void {
    const solana_zig = try activeDirectSolanaZig(allocator, options.environ);
    defer allocator.free(solana_zig);

    try buildBpfDirectWith(allocator, io, solana_zig, options);
}

/// Parses the SOLANA_ZIG environment value into a command/path that the BPF
/// builder (and `omlz doctor`) should invoke. Empty/missing/`"1"` map to the
/// default `solana-zig` PATH lookup; `"0"` is rejected to preserve the
/// CHANGELOG contract that legacy fallbacks are no longer supported; any other
/// value is returned verbatim as a direct command or absolute path.
pub fn parseSolanaZigEnv(raw: []const u8) ![]const u8 {
    const env_val = std.mem.trim(u8, raw, " \t\r\n");
    if (env_val.len == 0) {
        return "solana-zig";
    }
    if (std.mem.eql(u8, env_val, "1")) {
        return "solana-zig";
    }
    if (std.mem.eql(u8, env_val, "0")) {
        return error.InvalidSolanaZigCommand;
    }
    return env_val;
}

fn activeDirectSolanaZig(allocator: Allocator, environ: std.process.Environ) ![]const u8 {
    const env_val_raw = std.process.Environ.getAlloc(environ, allocator, "SOLANA_ZIG") catch |err| switch (err) {
        error.EnvironmentVariableMissing => return try allocator.dupe(u8, "solana-zig"),
        else => return err,
    };
    defer allocator.free(env_val_raw);

    const resolved = try parseSolanaZigEnv(env_val_raw);
    return try allocator.dupe(u8, resolved);
}

fn appendVendoredSdkModuleArgs(
    allocator: Allocator,
    args: *std.ArrayList([]const u8),
    root_module_path: []const u8,
) !void {
    const root_module_arg = try std.fmt.allocPrint(allocator, "-Mroot={s}", .{root_module_path});
    try args.appendSlice(allocator, &.{
        "--dep",
        "vendored_sdk",
    });
    try args.append(allocator, root_module_arg);
    try args.appendSlice(allocator, &.{
        "--dep",
        "solana_program_sdk",
        "--dep",
        "solana_codec",
        "--dep",
        "spl_token",
        "--dep",
        "spl_ata",
        "--dep",
        "solana_system",
        "--dep",
        "spl_memo",
        "-Mvendored_sdk=" ++ vendored_sdk_runtime_root,
        "-Msolana_program_sdk=" ++ vendored_solana_program_sdk_root,
        "--dep",
        "solana_program_sdk",
        "-Msolana_codec=" ++ vendored_solana_codec_root,
        "--dep",
        "solana_program_sdk",
        "--dep",
        "solana_codec",
        "-Mspl_token=" ++ vendored_spl_token_root,
        "--dep",
        "solana_program_sdk",
        "-Mspl_ata=" ++ vendored_spl_ata_root,
        "--dep",
        "solana_program_sdk",
        "-Msolana_system=" ++ vendored_solana_system_root,
        "--dep",
        "solana_program_sdk",
        "-Mspl_memo=" ++ vendored_spl_memo_root,
    });
}

fn buildBpfDirectWith(allocator: Allocator, io: Io, solana_zig: []const u8, options: BpfBuildOptions) !void {
    // Materialize the BPF linker script
    try materializeLinkerScript(allocator, io);

    const emit_arg = try std.fmt.allocPrint(allocator, "-femit-bin={s}", .{options.output_path});
    defer allocator.free(emit_arg);

    var zig_argv = std.ArrayList([]const u8).empty;
    defer {
        for (zig_argv.items) |arg| {
            if (std.mem.startsWith(u8, arg, "-Mroot=")) allocator.free(arg);
        }
        zig_argv.deinit(allocator);
    }

    try zig_argv.appendSlice(allocator, &.{
        solana_zig,
        "build-lib",
        "-target",
        "sbf-solana",
        "-O",
        "ReleaseSmall",
        "-fPIC",
        "-fstrip",
        "-dynamic",
        "-fentry=entrypoint",
        "-T",
        "out/runtime/bpf.ld",
        "-z",
        "notext",
    });
    try appendVendoredSdkModuleArgs(allocator, &zig_argv, options.bpf_entry_path);
    try zig_argv.append(allocator, emit_arg);

    try runAndForward(allocator, io, zig_argv.items, null, error.BpfDirectBuildFailed, !options.quiet);
}

/// Materialize the BPF linker script used by solana-zig direct compilation.
fn materializeLinkerScript(allocator: Allocator, io: Io) !void {
    _ = allocator;
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, "out/runtime");
    try cwd.writeFile(io, .{
        .sub_path = "out/runtime/bpf.ld",
        .data =
        \\PHDRS
        \\{
        \\text PT_LOAD  ;
        \\rodata PT_LOAD ;
        \\data PT_LOAD ;
        \\dynamic PT_DYNAMIC ;
        \\}
        \\SECTIONS
        \\{
        \\    . = SIZEOF_HEADERS;
        \\    .text : { *(.text*) } :text
        \\    .rodata : { *(.rodata*) } :rodata
        \\    .data.rel.ro : { *(.data.rel.ro*) } :rodata
        \\    .dynamic : { *(.dynamic) } :dynamic
        \\    .dynsym : { *(.dynsym) } :data
        \\    .dynstr : { *(.dynstr) } :data
        \\    .rel.dyn : { *(.rel.dyn) } :data
        \\    /DISCARD/ : {
        \\    *(.eh_frame*)
        \\    *(.gnu.hash*)
        \\    *(.hash*)
        \\    }
        \\}
        ,
        .flags = .{ .truncate = true },
    });
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
            .ArrayLit => |value| {
                for (value.elems) |elem| try self.collectExpr(elem);
            },
            .ArrayGet => |value| {
                try self.collectExpr(value.arr);
                try self.collectExpr(value.idx);
            },
            .ArrayLength => |value| try self.collectExpr(value.arr),
            .ArraySet => |value| {
                try self.collectExpr(value.arr);
                try self.collectExpr(value.idx);
                try self.collectExpr(value.value);
            },
            .ArrayMake => |value| try self.collectExpr(value.init),
            .RefMake => |value| try self.collectExpr(value.init),
            .RefGet => |value| try self.collectExpr(value.target),
            .RefSet => |value| {
                try self.collectExpr(value.target);
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

fn findLlvmObjcopy(allocator: Allocator, io: Io) ![]const u8 {
    if (try detectHomebrewLlvmPrefix(allocator, io)) |prefix| {
        defer allocator.free(prefix);
        const candidate = try std.fs.path.join(allocator, &.{ prefix, "bin", "llvm-objcopy" });
        errdefer allocator.free(candidate);
        if (commandAvailable(allocator, io, candidate)) return candidate;
        allocator.free(candidate);
    }

    const candidates = [_][]const u8{
        "llvm-objcopy",
        "/opt/homebrew/bin/llvm-objcopy",
        "/usr/local/bin/llvm-objcopy",
        "/usr/bin/llvm-objcopy",
    };
    for (candidates) |path| {
        if (commandAvailable(allocator, io, path)) {
            return allocator.dupe(u8, path);
        }
    }

    return error.FileNotFound;
}

fn detectHomebrewLlvmPrefix(allocator: Allocator, io: Io) !?[]const u8 {
    if (builtin.os.tag != .macos) return null;

    const roots = [_][]const u8{ "/opt/homebrew/opt", "/usr/local/opt" };
    for (roots) |root| {
        const root_dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch continue;
        defer root_dir.close(io);

        var iter = root_dir.iterate();
        while (true) {
            const entry = iter.next(io) catch continue;
            if (entry == null) break;
            const next = entry.?;
            if (next.kind != .directory) continue;
            if (!std.mem.startsWith(u8, next.name, "llvm")) continue;

            const prefix = try std.fs.path.join(allocator, &.{ root, next.name });
            const candidate = try std.fs.path.join(allocator, &.{ prefix, "bin", "llvm-objcopy" });
            const has_objcopy = commandAvailable(allocator, io, candidate);
            allocator.free(candidate);
            if (has_objcopy) return prefix;
            allocator.free(prefix);
        }
    }

    return null;
}

fn commandAvailable(allocator: Allocator, io: Io, path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.Io.Dir.accessAbsolute(io, path, .{ .execute = true }) catch return false;
        return true;
    }

    const argv = [_][]const u8{ path, "--version" };
    const completed = std.process.run(allocator, io, .{ .argv = &argv }) catch return false;
    defer allocator.free(completed.stdout);
    defer allocator.free(completed.stderr);
    return switch (completed.term) {
        .exited => |code| code == 0,
        .signal, .stopped, .unknown => false,
    };
}

/// Stable warning emitted at most once per `buildBpf` invocation when
/// `llvm-objcopy` cannot be located on PATH. Exposed for tests that assert
/// the exact byte sequence appears on stderr.
pub const llvm_objcopy_missing_warning =
    "warning: llvm-objcopy not found on PATH; .zxcaml.srcmap section will not be embedded in the .so. The .map sidecar is still written. omlz unmap --map can still resolve PCs.\n";

/// Pure helper that decides whether to emit the missing-`llvm-objcopy`
/// warning and writes it to the given writer if so. Returns `true` when the
/// warning was just emitted (and updates the flag so subsequent calls in the
/// same build stay silent), `false` when the flag had already been set.
fn maybeEmitObjcopyMissingWarning(
    warned_missing_objcopy: *bool,
    writer: *std.Io.Writer,
) !bool {
    if (warned_missing_objcopy.*) return false;
    warned_missing_objcopy.* = true;
    try writer.writeAll(llvm_objcopy_missing_warning);
    return true;
}

fn embedSourceMapSection(
    allocator: Allocator,
    io: Io,
    output_path: []const u8,
    schema: srcmap.Schema,
    warned_missing_objcopy: *bool,
) !void {
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

    const objcopy = findLlvmObjcopy(allocator, io) catch {
        // llvm-objcopy not available (e.g. Ubuntu CI); skip source map
        // embedding after emitting a single, non-fatal warning so users know
        // the .so has no embedded `.zxcaml.srcmap` section and must rely on
        // the `.map` sidecar via `omlz unmap --map`.
        emitObjcopyMissingWarningToStderr(io, warned_missing_objcopy) catch {};
        return;
    };
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

fn emitObjcopyMissingWarningToStderr(io: Io, warned_missing_objcopy: *bool) !void {
    var buffer: [1024]u8 = undefined;
    var file_writer: Io.File.Writer = .init(.stderr(), io, &buffer);
    const writer = &file_writer.interface;
    _ = try maybeEmitObjcopyMissingWarning(warned_missing_objcopy, writer);
    try writer.flush();
}

fn writeToolStderr(io: Io, bytes: []const u8) !void {
    // External tooling may emit noisy `dlopen` warnings about static LLVM archives
    // on macOS. Static archives cannot be loaded with dlopen, so suppress only
    // those probe lines while preserving genuine dynamic-library diagnostics.
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

test "llvm-objcopy missing warning emits exactly once per build" {
    const allocator = std.testing.allocator;
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();

    var warned: bool = false;

    const first_emitted = try maybeEmitObjcopyMissingWarning(&warned, &output.writer);
    try std.testing.expect(first_emitted);
    try std.testing.expect(warned);
    try std.testing.expectEqualStrings(llvm_objcopy_missing_warning, output.written());

    const second_emitted = try maybeEmitObjcopyMissingWarning(&warned, &output.writer);
    try std.testing.expect(!second_emitted);
    // Buffer length must not have grown on the second call.
    try std.testing.expectEqualStrings(llvm_objcopy_missing_warning, output.written());

    // The warning must contain the user-facing guidance that the sidecar is
    // still usable via `omlz unmap --map` so callers know the fallback path.
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "llvm-objcopy not found on PATH") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), ".zxcaml.srcmap section will not be embedded") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "omlz unmap --map") != null);
}

test "static archive LLVM dlopen warnings are filtered narrowly" {
    try std.testing.expect(isStaticArchiveDlopenWarning(
        "unable to open LLVM shared lib /path/to/llvm/lib/libLLVMAnalysis.a: dlopen failed",
    ));
    try std.testing.expect(!isStaticArchiveDlopenWarning(
        "unable to open LLVM shared lib /path/to/llvm/lib/libLLVM.dylib: dlopen failed",
    ));
    try std.testing.expect(!isStaticArchiveDlopenWarning(
        "error: direct build failed to parse out/program.bc",
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

fn testExitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        .signal, .stopped, .unknown => 1,
    };
}

test "BPF source env parser accepts trimmed values" {
    try std.testing.expectEqualStrings("solana-zig", try parseSolanaZigEnv("1"));
    try std.testing.expectEqualStrings("solana-zig", try parseSolanaZigEnv(" 1 \n"));
    try std.testing.expectEqualStrings("solana-zig", try parseSolanaZigEnv("   "));
    try std.testing.expectError(error.InvalidSolanaZigCommand, parseSolanaZigEnv("0"));
    try std.testing.expectEqualStrings("/tmp/custom-solana-zig", try parseSolanaZigEnv(" /tmp/custom-solana-zig \t"));
}

test "BPF env parser maps empty/missing env to direct path" {
    const allocator = std.testing.allocator;

    const direct_env = try activeDirectSolanaZig(allocator, std.process.Environ.empty);
    defer allocator.free(direct_env);

    try std.testing.expectEqualStrings("solana-zig", direct_env);
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
