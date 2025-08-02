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
        std.io.getStdIn()
    else
        std.fs.cwd().openFile(in_filename, .{}) catch {
            std.log.err("Failed to open {s}", .{in_filename});
            printUsage(true);
            return;
        };
    defer in_file.close();

    var buffered_reader = std.io.bufferedReader(in_file.reader());
    const reader = buffered_reader.reader();

    const xnb = Xnb.parse(allocator, reader.any()) catch |err| {
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
        .effect => |effect| {
            print("Dumping Effect bytecode", .{});

            try dumpToFile(allocator, out_filename, "fx.bin", effect.bytecode);
        },
        .texture_2d => |texture| {
            const pixel_format_name = if (texture.pixel_format) |p| try std.ascii.allocUpperString(allocator, @tagName(p)) else "(unknown pixel format)";
            const pixel_format_extension = if (texture.pixel_format) |p| @tagName(p) else "bin";

            print("Dumping {d}x{d} {s} texture data", .{ texture.width, texture.height, pixel_format_name });

            if (texture.mips.len == 0) {
                print("Texture has no mips", .{});
                return;
            }

            try dumpToFile(allocator, out_filename, pixel_format_extension, texture.mips[0]);

            for (texture.mips[1..], 1..) |mip, index| {
                const filename = try std.fmt.allocPrint(allocator, "{s}-{d}", .{ out_filename, index });

                try dumpToFile(allocator, filename, pixel_format_extension, mip);
            }
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
    const stderr = std.io.getStdErr().writer();
    var bw = std.io.bufferedWriter(stderr);
    const writer = bw.writer();

    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();
    nosuspend {
        writer.print(format ++ "\n", args) catch return;
        bw.flush() catch return;
    }
}

fn createOutFile(allocator: std.mem.Allocator, filename: *[]const u8, extension: []const u8) !std.fs.File {
    if (std.mem.eql(u8, filename.*, "-")) {
        return std.io.getStdOut();
    }

    filename.* = try std.mem.join(allocator, ".", &.{ filename.*, extension });

    return std.fs.cwd().createFile(filename.*, .{});
}

fn dumpToFile(allocator: std.mem.Allocator, filename: []const u8, extension: []const u8, data: []const u8) !void {
    var filename_with_extension = filename;

    const out_file = createOutFile(allocator, &filename_with_extension, extension) catch {
        std.log.err("Failed to open {s}", .{filename_with_extension});
        printUsage(true);
        return;
    };
    defer out_file.close();

    var buffered_writer = std.io.bufferedWriter(out_file.writer());
    const writer = buffered_writer.writer();

    writer.writeAll(data) catch {
        std.log.err("Error writing output file", .{});
        return;
    };
    try buffered_writer.flush();
}
