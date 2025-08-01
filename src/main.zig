const std = @import("std");
const xnb_reader = @import("xnb_reader");
const Xnb = xnb_reader.Xnb;
const XnbParseError = xnb_reader.XnbParseError;

var program_name: []const u8 = undefined;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    program_name = std.fs.path.basename(args.next() orelse "");

    const in_filename = args.next() orelse "-";
    const out_filename = args.next() orelse "-";

    if (std.mem.eql(u8, in_filename, "-h") or
        std.mem.eql(u8, in_filename, "--help") or
        std.mem.eql(u8, in_filename, "-?"))
    {
        printUsage(false);
        return;
    }

    const in_file = if (std.mem.eql(u8, in_filename, "-"))
        std.fs.File.stdin()
    else
        std.fs.cwd().openFile(in_filename, .{}) catch {
            std.log.err("Failed to open {s}", .{in_filename});
            printUsage(true);
            return;
        };
    defer in_file.close();

    const read_buffer = try allocator.alloc(u8, 4096);
    var reader = in_file.reader(read_buffer).interface;
    const xnb = Xnb.parse(allocator, &reader) catch |err| {
        std.log.err("{s}", .{switch (err) {
            XnbParseError.CompressedUnsupported => "Compressed XNB files are not supported",
            XnbParseError.InvalidMagic => "Invalid magic bytes in XNB file",
            XnbParseError.InvalidTexture2DSize => "Invalid Texture2D size",
            XnbParseError.InvalidTypeReaderIndex => "Invalid type reader index in XNB file",
            XnbParseError.SharedResourcesUnsupported => "Shared resources in XNB files are not supported",
            XnbParseError.UnknownTypeReader => "Unknown type reader in XNB file",
            else => "Error reading XNB file",
        }});
        return;
    };

    switch (xnb.resource) {
        .effect => {
            std.log.err("Effects not supported yet", .{});
            return;
        },
        .texture_2d => |texture| {
            if (texture.mips.len != 1) {
                std.log.err("Textures with more than 1 mip not supported yet", .{});
                return;
            }

            if (texture.pixel_format != .color) {
                std.log.err("Textures with pixel format other than RGBA are not supported yet", .{});
                return;
            }

            print("Dumping {d}x{d} RGBA texture data", .{ texture.width, texture.height });

            var out_filename_with_extension = out_filename;
            const out_file = createOutFile(allocator, &out_filename_with_extension, "rgba") catch {
                std.log.err("Failed to open {s}", .{out_filename_with_extension});
                printUsage(true);
                return;
            };
            defer out_file.close();

            const write_buffer = try allocator.alloc(u8, 4096);
            var file_writer = out_file.writer(write_buffer);
            var writer = file_writer.interface;
            writer.writeAll(texture.mips[0]) catch {
                std.log.err("Error writing output file", .{});
                return;
            };
            try file_writer.end();
        },
    }
}

fn printUsage(comptime following_error: bool) void {
    const reset = "\x1b[0m";
    const bold = "\x1b[1m";
    const underline = "\x1b[4m";

    print(if (following_error)
        \\
        \\Usage: {s}{s}{s} [{s}XNB file{s}] [{s}output file{s}]
    else
        \\Read content from an XNB file into an output file (extension will be added automatically):
        \\
        \\    {s}{s}{s} [{s}XNB file{s}] [{s}output file{s}]
        \\
        \\Omitting or writing "-" as either of the filenames will read from stdin or write to stdout respectively.
    , .{
        bold,
        program_name,
        reset,
        underline,
        reset,
        underline,
        reset,
    });
}

// Copied from std.log.defaultLog
fn print(comptime format: []const u8, args: anytype) void {
    var buffer: [64]u8 = undefined;
    const stderr = std.debug.lockStderrWriter(&buffer);
    defer std.debug.unlockStderrWriter();
    nosuspend stderr.print(format ++ "\n", args) catch return;
}

fn createOutFile(allocator: std.mem.Allocator, filename: *[:0]const u8, extension: []const u8) !std.fs.File {
    if (std.mem.eql(u8, filename.*, "-")) {
        return std.fs.File.stdout();
    }

    filename.* = try std.fmt.allocPrintSentinel(allocator, "{s}.{s}", .{ filename.*, extension }, 0);

    return std.fs.cwd().createFile(filename.*, .{});
}
