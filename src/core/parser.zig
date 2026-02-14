const std = @import("std");
const symbols = @import("symbols.zig");

pub fn parseModule(allocator: std.mem.Allocator, source: []const u8) !symbols.Index {
	var index = symbols.Index.init(allocator);
	errdefer index.deinit();

	var current_function: ?[]const u8 = null;
	var line_no: usize = 0;
	var lines = std.mem.splitScalar(u8, source, '\n');
	while (lines.next()) |raw_line| {
		line_no += 1;
		const trimmed = trimSourceLine(raw_line);
		if (trimmed.len == 0) continue;

		if (current_function == null) {
			if (std.mem.startsWith(u8, trimmed, "%") and std.mem.indexOf(u8, trimmed, "= type") != null) {
				const token = parseTokenAt(trimmed, 0) orelse continue;
				try index.addSymbol(.type_alias, token.token, line_no, null);
				if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq_pos| {
					const rhs = trimmed[eq_pos + 1 ..];
					try collectReferences(&index, rhs, line_no, null);
				}
				continue;
			}

			if (std.mem.startsWith(u8, trimmed, "@") and std.mem.indexOfScalar(u8, trimmed, '=') != null) {
				const token = parseTokenAt(trimmed, 0) orelse continue;
				try index.addSymbol(.global, token.token, line_no, null);
				if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq_pos| {
					const rhs = trimmed[eq_pos + 1 ..];
					try collectReferences(&index, rhs, line_no, null);
				}
				continue;
			}

			if (std.mem.startsWith(u8, trimmed, "declare ")) {
				const fn_name = parseNameAfterPrefix(trimmed, '@') orelse continue;
				try index.addSymbol(.function_decl, fn_name, line_no, null);
				continue;
			}

			if (std.mem.startsWith(u8, trimmed, "define ")) {
				const fn_name = parseNameAfterPrefix(trimmed, '@') orelse continue;
				try index.addSymbol(.function_def, fn_name, line_no, null);
				try parseParamDefinitions(&index, trimmed, line_no, fn_name);
				current_function = fn_name;
				continue;
			}

			if (std.mem.startsWith(u8, trimmed, "!") and std.mem.indexOfScalar(u8, trimmed, '=') != null) {
				const token = parseTokenAt(trimmed, 0) orelse continue;
				try index.addSymbol(.metadata, token.token, line_no, null);
				if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq_pos| {
					const rhs = trimmed[eq_pos + 1 ..];
					try collectReferences(&index, rhs, line_no, null);
				}
				continue;
			}

			continue;
		}

		if (trimmed[0] == '}') {
			current_function = null;
			continue;
		}

		if (trimmed[trimmed.len - 1] == ':') {
			const label_name = std.mem.trim(u8, trimmed[0 .. trimmed.len - 1], " \t");
			if (label_name.len > 0) {
				try index.addSymbol(.label, label_name, line_no, current_function);
			}
			continue;
		}

		if (std.mem.startsWith(u8, trimmed, "%")) {
			if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq_pos| {
				const lhs = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
				const def_token = parseTokenAt(lhs, 0) orelse continue;
				try index.addSymbol(.local, def_token.token, line_no, current_function);
				const rhs = trimmed[eq_pos + 1 ..];
				try collectReferences(&index, rhs, line_no, current_function);
				continue;
			}
		}

		try collectReferences(&index, trimmed, line_no, current_function);
	}

	return index;
}

const ParsedToken = struct {
	token: []const u8,
	next_index: usize,
};

fn trimSourceLine(line: []const u8) []const u8 {
	const uncommented = if (std.mem.indexOfScalar(u8, line, ';')) |comment_pos|
		line[0..comment_pos]
	else
		line;
	return std.mem.trim(u8, uncommented, " \t\r");
}

fn parseNameAfterPrefix(line: []const u8, prefix: u8) ?[]const u8 {
	const start = std.mem.indexOfScalar(u8, line, prefix) orelse return null;
	const token = parseTokenAt(line, start) orelse return null;
	return token.token;
}

fn parseTokenAt(line: []const u8, start: usize) ?ParsedToken {
	if (start >= line.len) return null;
	const prefix = line[start];
	if (prefix != '%' and prefix != '@' and prefix != '!') return null;
	if (start + 1 >= line.len) return null;

	if (line[start + 1] == '"') {
		var i = start + 2;
		while (i < line.len) {
			if (line[i] == '\\') {
				if (i + 1 >= line.len) return null;
				i += 2;
				continue;
			}
			if (line[i] == '"') break;
			i += 1;
		}
		if (i >= line.len) return null;
		return .{
			.token = line[start .. i + 1],
			.next_index = i + 1,
		};
	}

	var i = start + 1;
	while (i < line.len and isSymbolChar(line[i])) : (i += 1) {}
	if (i == start + 1) return null;

	return .{
		.token = line[start..i],
		.next_index = i,
	};
}

fn isSymbolChar(c: u8) bool {
	return std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '$' or c == '-';
}

fn parseParamDefinitions(index: *symbols.Index, line: []const u8, line_no: usize, function_name: []const u8) !void {
	const open = std.mem.indexOfScalar(u8, line, '(') orelse return;
	const close = std.mem.lastIndexOfScalar(u8, line, ')') orelse return;
	if (close <= open + 1) return;

	const params = line[open + 1 .. close];
	var cursor: usize = 0;
	while (cursor < params.len) {
		if (params[cursor] != '%') {
			cursor += 1;
			continue;
		}
		const token = parseTokenAt(params, cursor) orelse {
			cursor += 1;
			continue;
		};
		try index.addSymbol(.param, token.token, line_no, function_name);
		cursor = token.next_index;
	}
}

fn collectReferences(index: *symbols.Index, line: []const u8, line_no: usize, function_name: ?[]const u8) !void {
	var cursor: usize = 0;
	while (cursor < line.len) {
		const c = line[cursor];
		if (c != '%' and c != '@' and c != '!') {
			cursor += 1;
			continue;
		}
		const token = parseTokenAt(line, cursor) orelse {
			cursor += 1;
			continue;
		};
		try index.addReference(token.token, line_no, function_name);
		cursor = token.next_index;
	}
}

test "parser extracts top-level and function-scoped symbols" {
	const source =
		"%struct.Foo = type { i32 }\n" ++
		"@g = global i32 0\n" ++
		"declare void @ext(ptr)\n" ++
		"define i32 @main(i32 %argc, ptr %argv) {\n" ++
		"entry:\n" ++
		"  %0 = alloca i32\n" ++
		"  ret i32 0\n" ++
		"}\n";

	var index = try parseModule(std.testing.allocator, source);
	defer index.deinit();

	try std.testing.expectEqual(@as(usize, 1), index.countByKind(.type_alias));
	try std.testing.expectEqual(@as(usize, 1), index.countByKind(.global));
	try std.testing.expectEqual(@as(usize, 1), index.countByKind(.function_decl));
	try std.testing.expectEqual(@as(usize, 1), index.countByKind(.function_def));
	try std.testing.expectEqual(@as(usize, 2), index.countByKind(.param));
	try std.testing.expectEqual(@as(usize, 1), index.countByKind(.label));
	try std.testing.expectEqual(@as(usize, 1), index.countByKind(.local));

	try std.testing.expect(index.hasDefinition(.function_def, "@main", null, 4));
	try std.testing.expect(index.hasDefinition(.local, "%0", "@main", 6));
}

test "parser scopes numbered locals per function" {
	const source =
		"define void @a() {\n" ++
		"entry:\n" ++
		"  %0 = alloca i32\n" ++
		"  ret void\n" ++
		"}\n" ++
		"define void @b() {\n" ++
		"entry:\n" ++
		"  %0 = alloca i32\n" ++
		"  ret void\n" ++
		"}\n";

	var index = try parseModule(std.testing.allocator, source);
	defer index.deinit();

	try std.testing.expect(index.hasDefinition(.local, "%0", "@a", 3));
	try std.testing.expect(index.hasDefinition(.local, "%0", "@b", 8));
}

test "parser counts local references from rhs operands" {
	const source =
		"define void @f() {\n" ++
		"entry:\n" ++
		"  %x = alloca i32\n" ++
		"  store i32 1, ptr %x\n" ++
		"  store i32 2, ptr %x\n" ++
		"  ret void\n" ++
		"}\n";

	var index = try parseModule(std.testing.allocator, source);
	defer index.deinit();

	try std.testing.expectEqual(@as(usize, 2), index.countReferences("%x", "@f"));
}

test "parser collects top-level and metadata references" {
	const source =
		"@g1 = global i32 0\n" ++
		"@g2 = global ptr @g1\n" ++
		"!0 = !{i32 1}\n" ++
		"!llvm.module.flags = !{!0}\n" ++
		"define void @f() {\n" ++
		"entry:\n" ++
		"  ret void, !dbg !0\n" ++
		"}\n";

	var index = try parseModule(std.testing.allocator, source);
	defer index.deinit();

	try std.testing.expect(index.hasDefinition(.global, "@g1", null, 1));
	try std.testing.expect(index.hasDefinition(.global, "@g2", null, 2));
	try std.testing.expect(index.hasDefinition(.metadata, "!0", null, 3));
	try std.testing.expect(index.hasDefinition(.metadata, "!llvm.module.flags", null, 4));
	try std.testing.expectEqual(@as(usize, 1), index.countReferences("@g1", null));
	try std.testing.expectEqual(@as(usize, 1), index.countReferences("!0", null));
	try std.testing.expectEqual(@as(usize, 1), index.countReferences("!0", "@f"));
}

test "parser handles quoted identifiers with escaped quotes" {
	const source =
		"define void @\"fun\\\"name\"(ptr %\"arg\\\"name\") {\n" ++
		"entry:\n" ++
		"  %\"tmp\\\"id\" = alloca i32\n" ++
		"  store i32 1, ptr %\"tmp\\\"id\"\n" ++
		"  ret void\n" ++
		"}\n";

	var index = try parseModule(std.testing.allocator, source);
	defer index.deinit();

	try std.testing.expect(index.hasDefinition(.function_def, "@\"fun\\\"name\"", null, 1));
	try std.testing.expect(index.hasDefinition(.param, "%\"arg\\\"name\"", "@\"fun\\\"name\"", 1));
	try std.testing.expect(index.hasDefinition(.local, "%\"tmp\\\"id\"", "@\"fun\\\"name\"", 3));
	try std.testing.expectEqual(@as(usize, 1), index.countReferences("%\"tmp\\\"id\"", "@\"fun\\\"name\""));
}
