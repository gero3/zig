//! COFF import library generation for Windows
//! This module provides DEF file parsing and import library generation
//! to replace LLVM's WriteImportLibrary functionality in src/libs/mingw.zig

const std = @import("std");

pub const DefParser = @import("coff_def_parser.zig");
pub const ImportLibGenerator = @import("coff_import_lib_generator.zig");

pub const MachineType = enum(u16) {
    i386 = 0x014c,
    amd64 = 0x8664,

    pub fn fromTarget(target: std.Target) MachineType {
        return switch (target.cpu.arch) {
            .x86 => .i386,
            .x86_64 => .amd64,
            else => unreachable, // Only Windows x86/x64 supported for import libraries
        };
    }
};

/// Parse a DEF file and return module definition
pub fn parseDefFile(allocator: std.mem.Allocator, content: []const u8) !DefParser.ModuleDefinition {
    return DefParser.parseDefFile(allocator, content);
}

/// Generate an import library from DEF file content to a writer
pub fn generateImportLibraryToWriter(
    allocator: std.mem.Allocator,
    writer: anytype,
    def_content: []const u8,
    machine_type: MachineType,
) !void {
    var module_def = try DefParser.parseDefFile(allocator, def_content);
    defer module_def.deinit(allocator);

    try ImportLibGenerator.generateToWriter(allocator, writer, module_def, machine_type);
}

/// Generate an import library from DEF file content (deprecated - use generateImportLibraryToWriter)
pub fn generateImportLibrary(
    allocator: std.mem.Allocator,
    def_content: []const u8,
    output_path: []const u8,
    machine_type: MachineType,
) !void {
    var module_def = try DefParser.parseDefFile(allocator, def_content);
    defer module_def.deinit(allocator);

    try ImportLibGenerator.generate(allocator, module_def, output_path, machine_type);
}

/// Generate an import library from DEF file path (deprecated - use generateImportLibraryToWriter)
pub fn generateImportLibraryFromFile(
    allocator: std.mem.Allocator,
    def_file_path: []const u8,
    output_path: []const u8,
    machine_type: MachineType,
) !void {
    const def_content = try std.fs.cwd().readFileAlloc(allocator, def_file_path, std.math.maxInt(usize));
    defer allocator.free(def_content);

    try generateImportLibrary(allocator, def_content, output_path, machine_type);
}

/// Drop-in replacement for buildImportLib function in src/libs/mingw.zig
/// This replaces the LLVM-based implementation with pure Zig
/// Note: This function still uses file I/O for compatibility but should be replaced
/// with generateImportLibraryToWriter for memory-only operations
pub fn buildImportLib(
    arena: std.mem.Allocator,
    dst_lib_path: []const u8,
    def_path: []const u8,
    arch: std.Target.Cpu.Arch,
) !void {
    // Create a target for machine type conversion
    const target = std.Target{
        .cpu = std.Target.Cpu{
            .arch = arch,
            .model = std.Target.Cpu.Model.generic(arch),
            .features = std.Target.Cpu.Feature.Set.empty,
        },
        .os = std.Target.Os{
            .tag = .windows,
            .version_range = .{ .windows = .{
                .min = .win10,
                .max = .win10,
            } },
        },
        .abi = .msvc,
        .ofmt = .coff,
    };

    // Convert target architecture to machine type
    const machine_type = MachineType.fromTarget(target);

    // Generate the import library directly from the def file
    try generateImportLibraryFromFile(arena, def_path, dst_lib_path, machine_type);
}
