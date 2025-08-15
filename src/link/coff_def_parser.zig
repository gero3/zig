//! Module Definition (.def) file parser for Windows import libraries
//! This parser handles the format used by Microsoft's lib.exe and dlltool

const std = @import("std");

pub const ParseError = error{
    InvalidSyntax,
    MissingName,
    InvalidOrdinal,
    EmptyExportName,
    MalformedDescription,
    MalformedVersion,
    UnknownSection,
    DuplicateSection,
    OutOfMemory,
};

pub const ParseErrorInfo = struct {
    error_type: ParseError,
    line_number: u32,
    line_content: []const u8,
    message: []const u8,

    pub fn init(error_type: ParseError, line_number: u32, line_content: []const u8, message: []const u8) ParseErrorInfo {
        return ParseErrorInfo{
            .error_type = error_type,
            .line_number = line_number,
            .line_content = line_content,
            .message = message,
        };
    }
};

pub const ExportType = enum {
    function,
    data,
    constant,
};

pub const Export = struct {
    name: []const u8,
    internal_name: ?[]const u8,
    ordinal: ?u32,
    export_type: ExportType,
    is_private: bool,
    is_noname: bool,

    pub fn deinit(self: *Export, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.internal_name) |internal| {
            allocator.free(internal);
        }
    }
};

pub const ModuleDefinition = struct {
    name: ?[]const u8,
    description: ?[]const u8,
    version: ?[]const u8,
    exports: std.ArrayList(Export),

    pub fn init(allocator: std.mem.Allocator) ModuleDefinition {
        return ModuleDefinition{
            .name = null,
            .description = null,
            .version = null,
            .exports = std.ArrayList(Export).init(allocator),
        };
    }

    pub fn deinit(self: *ModuleDefinition, allocator: std.mem.Allocator) void {
        if (self.name) |name| allocator.free(name);
        if (self.description) |desc| allocator.free(desc);
        if (self.version) |version| allocator.free(version);

        for (self.exports.items) |*exp| {
            exp.deinit(allocator);
        }
        self.exports.deinit();
    }
};

/// Parse a DEF file from content string
pub fn parseDefFile(allocator: std.mem.Allocator, content: []const u8) !ModuleDefinition {
    var parser = DefParser.init(allocator);
    defer parser.deinit();
    
    return parser.parse(content);
}

pub const DefParser = struct {
    allocator: std.mem.Allocator,
    last_error: ?ParseErrorInfo = null,

    pub fn init(allocator: std.mem.Allocator) DefParser {
        return DefParser{
            .allocator = allocator,
            .last_error = null,
        };
    }

    pub fn deinit(self: *DefParser) void {
        _ = self;
    }

    pub fn getLastError(self: *const DefParser) ?ParseErrorInfo {
        return self.last_error;
    }

    fn setError(self: *DefParser, error_type: ParseError, line_number: u32, line_content: []const u8, message: []const u8) void {
        self.last_error = ParseErrorInfo.init(error_type, line_number, line_content, message);
    }

    pub fn parse(self: *DefParser, content: []const u8) !ModuleDefinition {
        var module_def = ModuleDefinition.init(self.allocator);
        errdefer module_def.deinit(self.allocator);

        var lines = std.mem.splitScalar(u8, content, '\n');
        var line_number: u32 = 0;
        var current_section: ?[]const u8 = null;

        while (lines.next()) |raw_line| {
            line_number += 1;
            
            // Remove carriage return if present and trim whitespace
            const line = std.mem.trim(u8, std.mem.trimRight(u8, raw_line, "\r"), " \t");
            
            // Skip empty lines and comments
            if (line.len == 0 or line[0] == ';') continue;

            // Check for section headers
            if (std.mem.eql(u8, line, "EXPORTS")) {
                current_section = "EXPORTS";
                continue;
            } else if (std.mem.startsWith(u8, line, "NAME")) {
                if (module_def.name != null) {
                    self.setError(ParseError.DuplicateSection, line_number, line, "NAME section already defined");
                    return ParseError.DuplicateSection;
                }
                if (line.len > 5) {
                    const name_part = std.mem.trim(u8, line[4..], " \t");
                    if (name_part.len > 0) {
                        module_def.name = try self.allocator.dupe(u8, name_part);
                    }
                }
                continue;
            } else if (std.mem.startsWith(u8, line, "DESCRIPTION")) {
                if (module_def.description != null) {
                    self.setError(ParseError.DuplicateSection, line_number, line, "DESCRIPTION section already defined");
                    return ParseError.DuplicateSection;
                }
                if (line.len > 11) {
                    const desc_part = std.mem.trim(u8, line[11..], " \t");
                    if (desc_part.len > 0) {
                        // Remove quotes if present
                        const desc = if (desc_part.len >= 2 and desc_part[0] == '"' and desc_part[desc_part.len - 1] == '"')
                            desc_part[1..desc_part.len - 1]
                        else
                            desc_part;
                        module_def.description = try self.allocator.dupe(u8, desc);
                    }
                }
                continue;
            } else if (std.mem.startsWith(u8, line, "VERSION")) {
                if (module_def.version != null) {
                    self.setError(ParseError.DuplicateSection, line_number, line, "VERSION section already defined");
                    return ParseError.DuplicateSection;
                }
                if (line.len > 7) {
                    const version_part = std.mem.trim(u8, line[7..], " \t");
                    if (version_part.len > 0) {
                        module_def.version = try self.allocator.dupe(u8, version_part);
                    }
                }
                continue;
            }

            // Process content based on current section
            if (current_section) |section| {
                if (std.mem.eql(u8, section, "EXPORTS")) {
                    const export_entry = self.parseExportLine(line, line_number) catch |err| {
                        return err;
                    };
                    try module_def.exports.append(export_entry);
                }
            } else {
                // Unknown directive outside of known sections
                self.setError(ParseError.UnknownSection, line_number, line, "Unknown directive or content outside known section");
                return ParseError.UnknownSection;
            }
        }

        return module_def;
    }

    fn parseExportLine(self: *DefParser, line: []const u8, line_number: u32) !Export {
        var export_entry = Export{
            .name = "",
            .internal_name = null,
            .ordinal = null,
            .export_type = .function,
            .is_private = false,
            .is_noname = false,
        };

        // Split by whitespace and parse components
        var parts = std.ArrayList([]const u8).init(self.allocator);
        defer parts.deinit();

        var it = std.mem.tokenizeAny(u8, line, " \t");
        while (it.next()) |part| {
            try parts.append(part);
        }

        if (parts.items.len == 0) {
            self.setError(ParseError.EmptyExportName, line_number, line, "Empty export line");
            return ParseError.EmptyExportName;
        }

        // First part is the export name, possibly with internal name
        const first_part = parts.items[0];
        if (std.mem.indexOf(u8, first_part, "=")) |eq_index| {
            // External=Internal format
            export_entry.name = try self.allocator.dupe(u8, first_part[0..eq_index]);
            export_entry.internal_name = try self.allocator.dupe(u8, first_part[eq_index + 1..]);
        } else {
            export_entry.name = try self.allocator.dupe(u8, first_part);
        }

        if (export_entry.name.len == 0) {
            export_entry.deinit(self.allocator);
            self.setError(ParseError.EmptyExportName, line_number, line, "Export name cannot be empty");
            return ParseError.EmptyExportName;
        }

        // Parse additional attributes
        for (parts.items[1..]) |part| {
            if (std.mem.startsWith(u8, part, "@")) {
                // Ordinal
                const ordinal_str = part[1..];
                export_entry.ordinal = std.fmt.parseInt(u32, ordinal_str, 10) catch {
                    export_entry.deinit(self.allocator);
                    self.setError(ParseError.InvalidOrdinal, line_number, line, "Invalid ordinal number");
                    return ParseError.InvalidOrdinal;
                };
            } else if (std.mem.eql(u8, part, "PRIVATE")) {
                export_entry.is_private = true;
            } else if (std.mem.eql(u8, part, "NONAME")) {
                export_entry.is_noname = true;
            } else if (std.mem.eql(u8, part, "DATA")) {
                export_entry.export_type = .data;
            } else if (std.mem.eql(u8, part, "CONSTANT")) {
                export_entry.export_type = .constant;
            }
            // Ignore unknown attributes for compatibility
        }

        return export_entry;
    }
};

test "parse simple def file" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    const def_content =
        \\EXPORTS
        \\CreateFileA
        \\CreateFileW
        \\ReadFile @1
        \\WriteFile @2 PRIVATE
    ;
    
    var module_def = try parseDefFile(allocator, def_content);
    defer module_def.deinit(allocator);
    
    try testing.expect(module_def.exports.items.len == 4);
    try testing.expectEqualStrings("CreateFileA", module_def.exports.items[0].name);
    try testing.expectEqualStrings("CreateFileW", module_def.exports.items[1].name);
    try testing.expect(module_def.exports.items[2].ordinal.? == 1);
    try testing.expect(module_def.exports.items[3].is_private);
}

test "parse def file with name and description" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    const def_content =
        \\NAME KERNEL32
        \\DESCRIPTION "Windows Kernel API"
        \\VERSION 10.0
        \\EXPORTS
        \\CreateFileA
    ;
    
    var module_def = try parseDefFile(allocator, def_content);
    defer module_def.deinit(allocator);
    
    try testing.expectEqualStrings("KERNEL32", module_def.name.?);
    try testing.expectEqualStrings("Windows Kernel API", module_def.description.?);
    try testing.expectEqualStrings("10.0", module_def.version.?);
}
