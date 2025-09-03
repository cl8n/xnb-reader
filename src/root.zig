const std = @import("std");

pub const Effect = struct {
    bytecode: []u8,

    fn parse(allocator: std.mem.Allocator, reader: *std.io.Reader) !@This() {
        const size = try reader.takeInt(u32, .little);
        const bytecode = try reader.readAlloc(allocator, size);

        return .{ .bytecode = bytecode };
    }
};

pub const PixelFormat = enum(u32) {
    // TODO: Not sure why this enum appears to be offset by 1. Find/link documentation
    /// "Color"
    rgba = 1,
    bgr565,
    bgra5551,
    bgra4444,
    dxt1,
    dxt3,
    dxt5,
    normalized_byte2,
    normalized_byte4,
    rgba1010102,
    rg32,
    rgba64,
    alpha8,
    single,
    vector2,
    vector4,
    half_single,
    half_vector2,
    half_vector4,
    hdr_blendable,
};

pub const Texture2D = struct {
    pixel_format: ?PixelFormat,
    width: u32,
    height: u32,
    mips: [][]u8,

    fn parse(allocator: std.mem.Allocator, reader: *std.io.Reader) !@This() {
        var texture: @This() = undefined;

        texture.pixel_format = reader.takeEnum(PixelFormat, .little) catch |err| switch (err) {
            error.InvalidEnumTag => null,
            else => return err,
        };
        texture.width = try reader.takeInt(u32, .little);
        texture.height = try reader.takeInt(u32, .little);

        if (texture.width == 0 or texture.height == 0) {
            return XnbParseError.InvalidTexture2DSize;
        }

        const mip_count = try reader.takeInt(u32, .little);
        texture.mips = try allocator.alloc([]u8, mip_count);

        for (texture.mips) |*mip| {
            const size = try reader.takeInt(u32, .little);
            mip.* = try reader.readAlloc(allocator, size);
        }

        return texture;
    }
};

pub const XnbParseError = error{
    CompressedUnsupported,
    InvalidMagic,
    InvalidTexture2DSize,
    InvalidTypeReaderIndex,
    SharedResourcesUnsupported,
    UnknownTypeReader,
};

pub const Platform = enum {
    windows,
    windows_phone,
    xbox_360,
};

pub const Xnb = struct {
    /// Supported platforms for this resource.
    platform: ?Platform,
    /// Version number that determines compatibility with releases of XNA Game Studio.
    version: u8,
    /// Raw flags. (TODO: parse)
    flags: u8,
    /// Size of the file.
    size: u32,
    /// Metadata of readers used to parse the content of the file.
    type_readers: []TypeReader,
    /// The resource contained in the file.
    resource: ResourceType,

    pub const TypeReader = struct {
        version: i32,
        tag: ResourceTypeTag,
    };

    pub const ResourceTypeTag = enum {
        effect,
        texture_2d,
    };

    pub const ResourceType = union(ResourceTypeTag) {
        effect: Effect,
        texture_2d: Texture2D,
    };

    /// Parse an XNB file from a reader.
    pub fn parse(allocator: std.mem.Allocator, reader: *std.io.Reader) !@This() {
        var xnb: @This() = undefined;

        try xnb.parseHeader(allocator, reader);
        try xnb.parseResource(allocator, reader);

        // TODO check that size is correct

        return xnb;
    }

    fn parseHeader(self: *@This(), allocator: std.mem.Allocator, reader: *std.io.Reader) !void {
        // Handle osu!stable special case where an empty header can indicate
        // that this XNB file contains a single Texture2D
        if (std.mem.eql(u8, try reader.peekArray(13), &[_]u8{0} ** 13)) {
            self.platform = .windows;
            self.version = 1;
            self.flags = 0;
            self.size = 0;

            reader.toss(13);

            return;
        }

        if (!std.mem.eql(u8, try reader.takeArray(3), "XNB")) {
            return XnbParseError.InvalidMagic;
        }

        self.platform = switch (try reader.takeByte()) {
            'w' => .windows,
            'm' => .windows_phone,
            'x' => .xbox_360,
            else => null,
        };
        self.version = try reader.takeByte();
        self.flags = try reader.takeByte();

        if (self.flags & 0x80 != 0) {
            return XnbParseError.CompressedUnsupported;
        }

        self.size = try reader.takeInt(u32, .little);

        const type_reader_count = try reader.takeLeb128(u32);
        self.type_readers = try allocator.alloc(TypeReader, type_reader_count);

        for (self.type_readers) |*type_reader| {
            const type_reader_name = try readString(allocator, reader);
            type_reader.version = try reader.takeInt(i32, .little);

            const type_reader_names = [_][]const u8{
                "Microsoft.Xna.Framework.Content.EffectReader",
                "Microsoft.Xna.Framework.Content.Texture2DReader",
            };

            type_reader.tag = blk: {
                for (type_reader_names, 0..) |name, index| {
                    if (std.mem.eql(u8, type_reader_name, name)) {
                        break :blk switch (index) {
                            0 => .effect,
                            1 => .texture_2d,
                            else => unreachable,
                        };
                    }
                }
                return XnbParseError.UnknownTypeReader;
            };

            // TODO validate type reader tag + version
        }

        if (try reader.takeLeb128(u32) != 0) {
            return XnbParseError.SharedResourcesUnsupported;
        }
    }

    fn parseResource(self: *@This(), allocator: std.mem.Allocator, reader: *std.io.Reader) !void {
        var type_reader_index = try reader.takeLeb128(u32);

        if (type_reader_index == 0) {
            return;
        }

        type_reader_index -= 1;

        if (type_reader_index >= self.type_readers.len) {
            return XnbParseError.InvalidTypeReaderIndex;
        }

        const type_reader = self.type_readers[type_reader_index];

        self.resource = switch (type_reader.tag) {
            .effect => .{ .effect = try Effect.parse(allocator, reader) },
            .texture_2d => .{ .texture_2d = try Texture2D.parse(allocator, reader) },
        };
    }
};

/// Read a string with its length indicated by a LEB128.
fn readString(allocator: std.mem.Allocator, reader: *std.io.Reader) ![]u8 {
    const length = try reader.takeLeb128(u32);

    return reader.readAlloc(allocator, length);
}
