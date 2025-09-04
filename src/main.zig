const std = @import("std");
const xnb_reader = @import("xnb_reader");
const Xnb = xnb_reader.Xnb;
const XnbParseError = xnb_reader.XnbParseError;

var program_name: []const u8 = undefined;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var options = try ProgramOptions.parse(allocator);
    defer options.deinit(allocator);

    if (options.exit) {
        return;
    }

    const in_filename = options.in_filename orelse "-";
    const out_filename = options.out_filename orelse "-";

    const in_file = if (std.mem.eql(u8, in_filename, "-"))
        std.fs.File.stdin()
    else
        std.fs.cwd().openFile(in_filename, .{}) catch {
            std.log.err("Failed to open {s}", .{in_filename});
            printUsage(true);
            return;
        };
    defer in_file.close();

    var file_reader_buffer: [1024]u8 = undefined;
    var file_reader = in_file.reader(&file_reader_buffer);
    const reader = &file_reader.interface;
    const xnb = Xnb.parse(allocator, reader) catch |err| {
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

            if (options.pipe_command_template != null and
                texture.mips.len == 1 and
                texture.pixel_format == .rgba)
            {
                const child_process_args = try getChildProcessArgs(allocator, options.pipe_command_template.?, .{
                    .width = texture.width,
                    .height = texture.height,
                    .depth = if (texture.pixel_format == .rgba) 8 else unreachable,
                });
                defer {
                    for (child_process_args) |arg| allocator.free(arg);
                    allocator.free(child_process_args);
                }

                var child_process = std.process.Child.init(child_process_args, allocator);
                child_process.stdin_behavior = .Pipe;

                try child_process.spawn();
                errdefer _ = child_process.kill() catch {};

                var stdin_writer_buffer: [1024]u8 = undefined;
                var stdin_writer = child_process.stdin.?.writer(&stdin_writer_buffer);
                const writer = &stdin_writer.interface;

                writer.writeAll(texture.mips[0]) catch {};
                writer.flush() catch {};

                switch (try child_process.wait()) {
                    .Exited => |status| std.process.exit(status),
                    else => _ = child_process.kill() catch {},
                }

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

const ProgramOptions = struct {
    exit: bool = false,
    in_filename: ?[]const u8 = null,
    out_filename: ?[]const u8 = null,
    pipe_command_template: ?[]const []const u8 = null,

    pub fn parse(allocator: std.mem.Allocator) !@This() {
        var args = try std.process.argsWithAllocator(allocator);
        defer args.deinit();

        program_name = std.fs.path.basename(args.next() orelse "");

        var options = @This(){};
        var positional_argument_index: u32 = 0;
        var skip_non_positional = false;

        while (args.next()) |arg| {
            if (!skip_non_positional) {
                if (std.mem.eql(u8, arg, "--")) {
                    skip_non_positional = true;
                    continue;
                }

                if (std.mem.eql(u8, arg, "-h") or
                    std.mem.eql(u8, arg, "--help") or
                    std.mem.eql(u8, arg, "-?"))
                {
                    printUsage(false);
                    options.exit = true;
                    break;
                }

                if (std.mem.eql(u8, arg, "--pipe")) {
                    var remaining_args = std.ArrayList([]const u8){};

                    while (args.next()) |remaining_arg| {
                        try remaining_args.append(allocator, remaining_arg);
                    }

                    if (remaining_args.items.len < 1) {
                        std.log.err("Missing pipe program", .{});
                        printUsage(true);
                        options.exit = true;
                        break;
                    }

                    options.pipe_command_template = try remaining_args.toOwnedSlice(allocator);
                    break;
                }
            }

            switch (positional_argument_index) {
                0 => options.in_filename = arg,
                1 => options.out_filename = arg,
                else => {}, // TODO print usage?
            }

            positional_argument_index += 1;
        }

        if (options.out_filename != null and options.pipe_command_template != null) {
            std.log.err("Cannot specify both output file and pipe program", .{});
            printUsage(true);
            options.exit = true;
        }

        return options;
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.pipe_command_template) |slice| {
            allocator.free(slice);
        }

        self.* = undefined;
    }
};

fn printUsage(comptime following_error: bool) void {
    const reset = "\x1b[0m";
    const bold = "\x1b[1m";
    const underline = "\x1b[4m";

    print(if (following_error)
        \\
        \\Usage: {s}{s}{s} [{s}XNB file{s}] [{s}output file{s}]
        \\       {s}{s}{s} [{s}XNB file{s}] --pipe {s}program{s} [{s}argument templates{s}...]
    else
        \\Read content from an XNB file into an output file (extension will be added automatically):
        \\
        \\    {s}{s}{s} [{s}XNB file{s}] [{s}output file{s}]
        \\
        \\Omitting or writing "-" as either of the filenames will read from stdin or write to stdout respectively.
        \\
        \\
        \\Read content from an XNB file and pipe the result to a program with templated arguments. Currently only supports Texture2D files with 1 mip and RGBA pixel format.
        \\
        \\    {s}{s}{s} [{s}XNB file{s}] --pipe {s}program{s} [{s}argument templates{s}...]
        \\
        \\The supported templates are {{width}}, {{height}}, and {{depth}}.
    , .{
        bold,
        program_name,
        reset,
        underline,
        reset,
        underline,
        reset,
        bold,
        program_name,
        reset,
        underline,
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

fn createOutFile(allocator: std.mem.Allocator, filename: *[]const u8, extension: []const u8) !std.fs.File {
    if (std.mem.eql(u8, filename.*, "-")) {
        return std.fs.File.stdout();
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

    var file_writer_buffer: [1024]u8 = undefined;
    var file_writer = out_file.writer(&file_writer_buffer);
    const writer = &file_writer.interface;

    writer.writeAll(data) catch {
        std.log.err("Error writing output file", .{});
        return;
    };
    try writer.flush();
}

fn getChildProcessArgs(allocator: std.mem.Allocator, argv: []const []const u8, template_values: anytype) ![]const []const u8 {
    const template_values_field_names = comptime blk: {
        const type_info = @typeInfo(@TypeOf(template_values));
        const fields = type_info.@"struct".fields;
        var field_names: [fields.len][]const u8 = undefined;

        for (fields, &field_names) |field, *name| {
            name.* = field.name;
        }

        break :blk &field_names;
    };

    const rendered_argv = try allocator.alloc([]u8, argv.len);

    for (argv, rendered_argv) |arg, *rendered_arg| {
        var rendered_arg_writer = try std.io.Writer.Allocating.initCapacity(allocator, arg.len);
        defer rendered_arg_writer.deinit();
        const writer = &rendered_arg_writer.writer;

        var pos: usize = 0;

        while (pos < arg.len) {
            const open_pos = std.mem.indexOfScalarPos(u8, arg, pos, '{') orelse break;
            try writer.writeAll(arg[pos..open_pos]);
            pos = open_pos + 1;

            while (pos < arg.len and std.ascii.isLower(arg[pos])) {
                pos += 1;
            }

            if (pos < arg.len and arg[pos] == '}') {
                const token = arg[open_pos + 1 .. pos];

                inline for (template_values_field_names) |field_name| {
                    if (std.mem.eql(u8, field_name, token)) {
                        const fmt = comptime blk: {
                            if (std.mem.eql(u8, field_name, "width")) break :blk "{d}";
                            if (std.mem.eql(u8, field_name, "height")) break :blk "{d}";
                            if (std.mem.eql(u8, field_name, "depth")) break :blk "{d}";
                            unreachable;
                        };

                        try writer.print(fmt, .{@field(template_values, field_name)});
                        pos += 1;
                        break;
                    }
                } else {
                    try writer.writeAll(arg[open_pos..pos]);
                }
            } else {
                try writer.writeAll(arg[open_pos..pos]);
            }
        }

        if (pos < arg.len) {
            try writer.writeAll(arg[pos..]);
        }

        rendered_arg.* = try rendered_arg_writer.toOwnedSlice();
    }

    return rendered_argv;
}
