const std = @import("std");
const builtin = @import("builtin");

pub fn parse(
    comptime Schema: type,
    args_iterator: anytype,
) !Schema {
    var result: Schema = .{};

    const Shorts = if (@hasDecl(Schema, "shorts")) Schema.shorts else struct {};
    comptime validateShorts(Schema, Shorts);

    var it = args_iterator;
    while (it.next()) |arg| {
        var flag_name: []const u8 = undefined;
        var exact_flag_name = false;

        if (std.mem.startsWith(u8, arg, "--")) {
            flag_name = arg[2..];
        } else if (std.mem.startsWith(u8, arg, "-")) {
            if (arg.len != 2) {
                if (!builtin.is_test) std.debug.print("Invalid short flag: {s}\n", .{arg});
                return error.InvalidFlag;
            }

            const short_char = arg[1];
            flag_name = blk: inline for (std.meta.fields(Shorts)) |field| {
                if (field.name[0] == short_char) {
                    break :blk @field(Shorts{}, field.name);
                }
            } else {
                if (!builtin.is_test) std.debug.print("Unknown short flag: {s}\n", .{arg});
                return error.UnknownFlag;
            };
            exact_flag_name = true;
        } else {
            if (!builtin.is_test) std.debug.print("Unexpected argument: {s}\n", .{arg});
            return error.UnexpectedArgument;
        }

        var matched = false;
        inline for (std.meta.fields(Schema)) |field| {
            if (exact_flag_name and std.mem.eql(u8, field.name, flag_name) or
                fieldMatchesFlag(field.name, flag_name))
            {
                matched = true;

                @field(result, field.name) = if (field.type == bool)
                    true
                else blk: {
                    const val = it.next() orelse {
                        if (!builtin.is_test) std.debug.print("Missing value for flag: {s}\n", .{arg});
                        return error.MissingValue;
                    };

                    break :blk if (field.type == []const u8)
                        val
                    else switch (@typeInfo(field.type)) {
                        .int => std.fmt.parseInt(field.type, val, 10) catch {
                            if (!builtin.is_test) std.debug.print("Invalid integer value for flag {s}: {s}\n", .{ arg, val });
                            return error.InvalidValue;
                        },
                        .float => std.fmt.parseFloat(field.type, val) catch {
                            if (!builtin.is_test) std.debug.print("Invalid float value for flag {s}: {s}\n", .{ arg, val });
                            return error.InvalidValue;
                        },
                        else => @compileError("Unsupported value type for field: " ++ field.name),
                    };
                };

                break;
            }
        }

        if (!matched) {
            if (!builtin.is_test) std.debug.print("Unknown flag: {s}\n", .{arg});
            return error.UnknownFlag;
        }
    }

    return result;
}

fn validateShorts(comptime Schema: type, comptime Shorts: type) void {
    inline for (std.meta.fields(Shorts)) |field| {
        if (field.name.len != 1) {
            @compileError("Short flag field name must be 1 character long: " ++ field.name);
        }
        if (field.type != []const u8) {
            @compileError("Short flag field value must be a string: " ++ field.name);
        }
        const long_name = @field(Shorts{}, field.name);
        if (!@hasField(Schema, long_name)) {
            @compileError("Short flag (" ++ field.name ++ ") points to non-existent long flag: " ++ long_name);
        }
    }
}

fn fieldMatchesFlag(comptime field_name: []const u8, flag_name: []const u8) bool {
    if (flag_name.len != field_name.len) return false;

    inline for (field_name, 0..) |c, i| {
        const expected = if (c == '_') '-' else c;
        if (flag_name[i] != expected) return false;
    }
    return true;
}

test "parse" {
    const Schema = struct {
        foo: bool = false,
        bar: u32 = 0,
        baz: []const u8 = "",
        val: f32 = 0.0,
    };
    var it = TestArgsIterator{
        .args = &[_][]const u8{ "--foo", "--bar", "42", "--baz", "hello", "--val", "3.14" },
    };
    const result = try parse(Schema, &it);
    try std.testing.expect(result.foo == true);
    try std.testing.expect(result.bar == 42);
    try std.testing.expect(std.mem.eql(u8, result.baz, "hello"));
    try std.testing.expect(result.val == 3.14);
}

test "parse with defaults" {
    const Schema = struct {
        foo: bool = true,
        bar: u32 = 123,
        baz: []const u8 = "default",
    };
    var it = TestArgsIterator{};
    const result = try parse(Schema, &it);
    try std.testing.expect(result.foo == true);
    try std.testing.expect(result.bar == 123);
    try std.testing.expect(std.mem.eql(u8, result.baz, "default"));
}

test "parse field with underscore" {
    const Schema = struct {
        foo_bar: bool = false,
        pub const shorts = struct { f: []const u8 = "foo_bar" };
    };
    {
        var it = TestArgsIterator{
            .args = &[_][]const u8{"--foo-bar"},
        };
        const result = try parse(Schema, &it);
        try std.testing.expect(result.foo_bar == true);
    }
    {
        var it = TestArgsIterator{
            .args = &[_][]const u8{"-f"},
        };
        const result = try parse(Schema, &it);
        try std.testing.expect(result.foo_bar == true);
    }
    {
        var it = TestArgsIterator{
            .args = &[_][]const u8{"--foo_bar"},
        };
        try std.testing.expectError(error.UnknownFlag, parse(Schema, &it));
    }
}

test "parse shorts" {
    const Schema = struct {
        pub const shorts = struct {
            v: []const u8 = "verbose",
            c: []const u8 = "count",
        };
        verbose: bool = false,
        count: i32 = 0,
        name: []const u8 = "",
    };
    var it = TestArgsIterator{
        .args = &[_][]const u8{ "-v", "--name", "zig", "-c", "-10" },
    };
    const result = try parse(Schema, &it);
    try std.testing.expect(result.verbose == true);
    try std.testing.expect(std.mem.eql(u8, result.name, "zig"));
    try std.testing.expect(result.count == -10);
}

test "error: unknown flags" {
    const Schema = struct { foo: bool = false };
    {
        var it = TestArgsIterator{ .args = &[_][]const u8{"--unknown"} };
        try std.testing.expectError(error.UnknownFlag, parse(Schema, &it));
    }
    {
        var it = TestArgsIterator{ .args = &[_][]const u8{"-x"} };
        try std.testing.expectError(error.UnknownFlag, parse(Schema, &it));
    }
}

test "error: missing values" {
    const Schema = struct {
        pub const shorts = struct { n: []const u8 = "number" };
        number: u32 = 0,
    };
    {
        var it = TestArgsIterator{ .args = &[_][]const u8{"--number"} };
        try std.testing.expectError(error.MissingValue, parse(Schema, &it));
    }
    {
        var it = TestArgsIterator{ .args = &[_][]const u8{"-n"} };
        try std.testing.expectError(error.MissingValue, parse(Schema, &it));
    }
}

test "error: invalid values" {
    {
        const Schema = struct { val: u32 = 0 };
        var it = TestArgsIterator{ .args = &[_][]const u8{ "--val", "not_a_number" } };
        try std.testing.expectError(error.InvalidValue, parse(Schema, &it));
    }
    {
        const Schema = struct { val: f32 = 0.0 };
        var it = TestArgsIterator{ .args = &[_][]const u8{ "--val", "abc" } };
        try std.testing.expectError(error.InvalidValue, parse(Schema, &it));
    }
}

test "error: malformed flags" {
    const Schema = struct {
        pub const shorts = struct { f: []const u8 = "foo" };
        foo: bool = false,
    };
    {
        var it = TestArgsIterator{ .args = &[_][]const u8{"-foo"} };
        try std.testing.expectError(error.InvalidFlag, parse(Schema, &it));
    }
    {
        var it = TestArgsIterator{ .args = &[_][]const u8{"foo"} };
        try std.testing.expectError(error.UnexpectedArgument, parse(Schema, &it));
    }
}

const TestArgsIterator = struct {
    args: []const []const u8 = &[_][]const u8{},
    index: usize = 0,

    pub fn next(self: *@This()) ?[]const u8 {
        if (self.index >= self.args.len) return null;
        defer self.index += 1;
        return self.args[self.index];
    }
};
