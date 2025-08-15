//! COFF import library generator for Windows
//! Generates .lib files from module definitions

const std = @import("std");
const DefParser = @import("coff_def_parser.zig");
const ModuleDefinition = DefParser.ModuleDefinition;
const Export = DefParser.Export;
const ExportType = DefParser.ExportType;

const ARCHIVE_SIGNATURE = "!<arch>\n";

// COFF Machine Types
const IMAGE_FILE_MACHINE_I386: u16 = 0x014c;
const IMAGE_FILE_MACHINE_AMD64: u16 = 0x8664;
const IMAGE_FILE_MACHINE_UNKNOWN: u16 = 0x0;
const IMAGE_SYM_CLASS_EXTERNAL = 2;
const IMAGE_SYM_DTYPE_FUNCTION = 0x20;
const IMAGE_SYM_TYPE_NULL = 0;

// Import Object Header constants
const IMPORT_OBJECT_HDR_SIG2: u16 = 0xffff;

// Type encoding constants
const IMPORT_TYPE_MASK: u8 = 0x3;
const NAME_TYPE_MASK: u8 = 0x7;
const NAME_TYPE_SHIFT: u8 = 2;

// Import Object Types
const IMPORT_OBJECT_CODE: u16 = 0;
const IMPORT_OBJECT_DATA: u16 = 1;
const IMPORT_OBJECT_CONST: u16 = 2;

// Import Name Types
const IMPORT_NAME_ORDINAL: u16 = 0;
const IMPORT_NAME_NAME: u16 = 1;
const IMPORT_NAME_NAME_NO_PREFIX: u16 = 2;
const IMPORT_NAME_NAME_UNDECORATE: u16 = 3;

pub const MachineType = @import("coff_import_lib.zig").MachineType;

// Convert MachineType enum to COFF machine constant
fn machineTypeToConstant(machine_type: MachineType) u16 {
    return @intFromEnum(machine_type);
}

// COFF structures for real import objects
const ImportObjectHeader = packed struct {
    sig1: u16, // Always IMPORT_OBJECT_HDR_SIG2
    sig2: u16, // Always IMPORT_OBJECT_HDR_SIG2
    version: u16, // Usually 0
    machine: u16, // Target machine type
    time_date_stamp: u32, // Timestamp
    size_of_data: u32, // Size of data following header
    ordinal_or_hint: u16, // Ordinal or hint
    type_info: u16, // Type and name info
    // Followed by: null-terminated symbol name, null-terminated DLL name
};

const ArchiveMemberHeader = struct {
    name: [16]u8, // Member name
    date: [12]u8, // File modification timestamp
    uid: [6]u8, // Owner ID
    gid: [6]u8, // Group ID
    mode: [8]u8, // File mode
    size: [10]u8, // File size in bytes
    end: [2]u8, // Ending characters (backtick and newline)
};

pub const GenerationError = error{
    InvalidExport,
    WriteError,
    OutOfMemory,
};

/// Generate an import library from a module definition into memory
pub fn generateToWriter(
    allocator: std.mem.Allocator,
    writer: anytype,
    module_def: ModuleDefinition,
    machine_type: MachineType,
) !void {
    // Write archive signature
    _ = try writer.writeAll(ARCHIVE_SIGNATURE);

    // Calculate total entries needed (one per export plus optional archive header)
    const num_exports = module_def.exports.items.len;
    if (num_exports == 0) return; // Nothing to generate

    // Determine module name
    const module_name = module_def.name orelse "UNKNOWN";

    // Generate import objects for each export
    for (module_def.exports.items) |export_entry| {
        try writeImportObject(allocator, writer, export_entry, module_name, machine_type);
    }
}

/// Generate an import library from a module definition (deprecated - use generateToWriter)
pub fn generate(
    allocator: std.mem.Allocator,
    module_def: ModuleDefinition,
    output_path: []const u8,
    machine_type: MachineType,
) !void {
    const file = std.fs.cwd().createFile(output_path, .{}) catch |err| switch (err) {
        error.AccessDenied => return GenerationError.WriteError,
        error.FileNotFound => return GenerationError.WriteError,
        error.IsDir => return GenerationError.WriteError,
        else => return err,
    };
    defer file.close();

    try generateToWriter(allocator, file.writer(), module_def, machine_type);
}

fn writeImportObject(
    allocator: std.mem.Allocator,
    writer: anytype,
    export_entry: Export,
    module_name: []const u8,
    machine_type: MachineType,
) !void {
    // Prepare symbol and DLL names
    const symbol_name = export_entry.name;
    const dll_name = try std.fmt.allocPrint(allocator, "{s}.dll", .{module_name});
    defer allocator.free(dll_name);

    // Calculate sizes
    const symbol_name_size = symbol_name.len + 1; // +1 for null terminator
    const dll_name_size = dll_name.len + 1; // +1 for null terminator
    const data_size = symbol_name_size + dll_name_size;
    const total_size = @sizeOf(ImportObjectHeader) + data_size;

    // Prepare import object header
    var header = ImportObjectHeader{
        .sig1 = IMPORT_OBJECT_HDR_SIG2,
        .sig2 = IMPORT_OBJECT_HDR_SIG2,
        .version = 0,
        .machine = machineTypeToConstant(machine_type),
        .time_date_stamp = 0, // Use 0 for reproducible builds
        .size_of_data = @intCast(data_size),
        .ordinal_or_hint = @intCast(export_entry.ordinal orelse 0),
        .type_info = calculateTypeInfo(export_entry),
    };

    // Create archive member header
    var member_header = try createArchiveMemberHeader(allocator, total_size);

    // Write archive member header
    try writer.writeAll(std.mem.asBytes(&member_header));

    // Write import object header
    try writer.writeAll(std.mem.asBytes(&header));

    // Write symbol name (null-terminated)
    try writer.writeAll(symbol_name);
    try writer.writeAll(&[_]u8{0});

    // Write DLL name (null-terminated)
    try writer.writeAll(dll_name);
    try writer.writeAll(&[_]u8{0});

    // Add padding if needed to align to even boundary
    if (total_size % 2 != 0) {
        try writer.writeAll(&[_]u8{0});
    }
}

fn calculateTypeInfo(export_entry: Export) u16 {
    var type_info: u16 = 0;

    // Set import type (lower 2 bits)
    const import_type: u16 = switch (export_entry.export_type) {
        .function => IMPORT_OBJECT_CODE,
        .data => IMPORT_OBJECT_DATA,
        .constant => IMPORT_OBJECT_CONST,
    };
    type_info |= import_type & IMPORT_TYPE_MASK;

    // Set name type (bits 2-4)
    const name_type: u16 = if (export_entry.ordinal != null)
        IMPORT_NAME_ORDINAL
    else if (export_entry.is_noname)
        IMPORT_NAME_ORDINAL
    else
        IMPORT_NAME_NAME;

    type_info |= (name_type & NAME_TYPE_MASK) << NAME_TYPE_SHIFT;

    return type_info;
}

fn createArchiveMemberHeader(allocator: std.mem.Allocator, size: usize) !ArchiveMemberHeader {
    var header = ArchiveMemberHeader{
        .name = [_]u8{' '} ** 16,
        .date = [_]u8{' '} ** 12,
        .uid = [_]u8{' '} ** 6,
        .gid = [_]u8{' '} ** 6,
        .mode = [_]u8{' '} ** 8,
        .size = [_]u8{' '} ** 10,
        .end = [_]u8{ '`', '\n' },
    };

    // Set a generic name for import objects
    const name_bytes = "/               ";
    @memcpy(header.name[0..name_bytes.len], name_bytes);

    // Set default values
    const date_str = "0           ";
    @memcpy(header.date[0..date_str.len], date_str);

    const id_str = "0     ";
    @memcpy(header.uid[0..id_str.len], id_str);
    @memcpy(header.gid[0..id_str.len], id_str);

    const mode_str = "100644  ";
    @memcpy(header.mode[0..mode_str.len], mode_str);

    // Convert size to decimal string
    const size_str = try std.fmt.allocPrint(allocator, "{d}", .{size});
    defer allocator.free(size_str);

    // Right-pad with spaces
    var i: usize = 0;
    while (i < size_str.len and i < 10) : (i += 1) {
        header.size[i] = size_str[i];
    }

    return header;
}

test "generate simple import library" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var module_def = ModuleDefinition.init(allocator);
    defer module_def.deinit(allocator);

    module_def.name = try allocator.dupe(u8, "test");

    try module_def.exports.append(Export{
        .name = try allocator.dupe(u8, "TestFunction"),
        .internal_name = null,
        .ordinal = null,
        .export_type = .function,
        .is_private = false,
        .is_noname = false,
    });

    // Generate to memory buffer first
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    try generateToWriter(allocator, buffer.writer(), module_def, .amd64);

    // Verify buffer has content
    try testing.expect(buffer.items.len > 0);

    // Optionally test by writing to file
    const temp_path = "test_output.lib";
    defer std.fs.cwd().deleteFile(temp_path) catch {};

    const file = try std.fs.cwd().createFile(temp_path, .{});
    defer file.close();
    try file.writeAll(buffer.items);

    // Verify file was created and has correct size
    const size = try file.getEndPos();
    try testing.expect(size == buffer.items.len);
}
