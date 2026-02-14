const std = @import("std");
const symbols = @import("symbols.zig");

const ParseToken = struct {
	token: []const u8,
	next_index: usize,
};

pub fn buildParamsJson(allocator: std.mem.Allocator, uri: []const u8, source: []const u8, index: *const symbols.Index) ![]u8 {
	var out: std.ArrayListUnmanaged(u8) = .{};
	errdefer out.deinit(allocator);
	try out.appendSlice(allocator, "{\"uri\":\"");
	try out.appendSlice(allocator, uri);
	try out.appendSlice(allocator, "\",\"diagnostics\":[");
	var wrote_any = false;

	for (index.references.items) |reference| {
		if (reference.name.len == 0 or reference.name[0] != '%') continue;
		const scope = reference.scope_function orelse continue;
		if (reference.name.len > 1 and hasDefinition(index, .label, reference.name[1..], scope)) continue;
		if (hasDefinition(index, .local, reference.name, scope)) continue;
		if (hasDefinition(index, .param, reference.name, scope)) continue;
		if (hasDefinition(index, .type_alias, reference.name, null)) continue;

		const message = try std.fmt.allocPrint(allocator, "undefined symbol {s}", .{reference.name});
		defer allocator.free(message);
		try appendDiagnostic(allocator, &out, &wrote_any, reference.line - 1, reference.name.len, 1, message);
	}

	var i: usize = 0;
	while (i < index.symbols.items.len) : (i += 1) {
		const symbol = index.symbols.items[i];
		if (!isDuplicateCheckedKind(symbol.kind)) continue;

		var seen_before = false;
		var j: usize = 0;
		while (j < i) : (j += 1) {
			const previous = index.symbols.items[j];
			if (previous.kind != symbol.kind) continue;
			if (!std.mem.eql(u8, previous.name, symbol.name)) continue;
			if (!scopeEqual(previous.scope_function, symbol.scope_function)) continue;
			seen_before = true;
			break;
		}
		if (!seen_before) continue;

		const message = try std.fmt.allocPrint(allocator, "duplicate definition {s}", .{symbol.name});
		defer allocator.free(message);
		try appendDiagnostic(allocator, &out, &wrote_any, symbol.line - 1, symbol.name.len, 1, message);
	}

	var in_function = false;
	var last_instruction_line: usize = 0;
	var last_instruction_len: usize = 0;
	var last_was_terminator = false;
	var ptr_locals: std.StringHashMapUnmanaged(void) = .{};
	defer ptr_locals.deinit(allocator);
	var line_no: usize = 0;
	var lines = std.mem.splitScalar(u8, source, '\n');
	while (lines.next()) |raw_line| {
		line_no += 1;
		const trimmed = trimSourceLine(raw_line);
		if (trimmed.len == 0) continue;

		if (std.mem.indexOf(u8, trimmed, "???") != null) {
			try appendDiagnostic(allocator, &out, &wrote_any, line_no - 1, trimmed.len, 1, "parse error");
		}

		if (!in_function and std.mem.startsWith(u8, trimmed, "define ")) {
			in_function = true;
			last_instruction_line = 0;
			last_instruction_len = 0;
			last_was_terminator = false;
			ptr_locals.clearRetainingCapacity();
			continue;
		}

		if (!in_function) continue;

		if (trimmed[0] == '}') {
			if (last_instruction_line > 0 and !last_was_terminator) {
				try appendDiagnostic(allocator, &out, &wrote_any, last_instruction_line - 1, last_instruction_len, 1, "missing terminator");
			}
			in_function = false;
			continue;
		}

		if (trimmed[trimmed.len - 1] == ':') continue;

		var instruction = trimmed;
		if (trimmed[0] == '%') {
			if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq_pos| {
				const lhs = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
				instruction = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");
				if (instructionStartsWithPrefix(instruction, "alloca")) {
					try ptr_locals.put(allocator, lhs, {});
				}
				if (instructionStartsWithPrefix(instruction, "add i32")) {
					var rhs_cursor: usize = 0;
					while (rhs_cursor < instruction.len) {
						if (instruction[rhs_cursor] != '%') {
							rhs_cursor += 1;
							continue;
						}
						const token = parsePrefixedTokenAt(instruction, rhs_cursor) orelse {
							rhs_cursor += 1;
							continue;
						};
						if (ptr_locals.contains(token.token)) {
							try appendDiagnostic(allocator, &out, &wrote_any, line_no - 1, token.token.len, 2, "type mismatch in add");
							break;
						}
						rhs_cursor = token.next_index;
					}
				}
			}
		}
		if (instruction.len == 0) continue;

		last_instruction_line = line_no;
		last_instruction_len = instruction.len;
		last_was_terminator = instructionStartsWithTerminator(instruction);
	}

	try out.appendSlice(allocator, "]}");
	return try out.toOwnedSlice(allocator);
}

fn appendDiagnostic(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), wrote_any: *bool, line: usize, len: usize, severity: u8, message: []const u8) !void {
	if (wrote_any.*) {
		try out.appendSlice(allocator, ",");
	}
	wrote_any.* = true;
	const piece = try std.fmt.allocPrint(
		allocator,
		"{{\"range\":{{\"start\":{{\"line\":{d},\"character\":0}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"severity\":{d},\"source\":\"llvm-lsp\",\"message\":\"{s}\"}}",
		.{ line, line, len, severity, message },
	);
	defer allocator.free(piece);
	try out.appendSlice(allocator, piece);
}

fn instructionStartsWithPrefix(instruction: []const u8, prefix: []const u8) bool {
	return std.mem.eql(u8, instruction, prefix) or
		(instruction.len > prefix.len and std.mem.startsWith(u8, instruction, prefix) and instruction[prefix.len] == ' ');
}

fn isDuplicateCheckedKind(kind: symbols.SymbolKind) bool {
	return switch (kind) {
		.function_def, .global, .type_alias, .local, .param, .label, .metadata => true,
		else => false,
	};
}

fn trimSourceLine(line: []const u8) []const u8 {
	const uncommented = if (std.mem.indexOfScalar(u8, line, ';')) |comment_pos|
		line[0..comment_pos]
	else
		line;
	return std.mem.trim(u8, uncommented, " \t\r");
}

fn instructionStartsWithTerminator(instruction: []const u8) bool {
	return std.mem.startsWith(u8, instruction, "ret ") or
		std.mem.eql(u8, instruction, "ret") or
		std.mem.startsWith(u8, instruction, "br ") or
		std.mem.startsWith(u8, instruction, "switch ") or
		std.mem.startsWith(u8, instruction, "indirectbr ") or
		std.mem.startsWith(u8, instruction, "invoke ") or
		std.mem.startsWith(u8, instruction, "callbr ") or
		std.mem.startsWith(u8, instruction, "resume ") or
		std.mem.startsWith(u8, instruction, "unreachable");
}

fn parsePrefixedTokenAt(line: []const u8, start: usize) ?ParseToken {
	if (start >= line.len) return null;
	const prefix = line[start];
	if (prefix != '%' and prefix != '@' and prefix != '!' and prefix != '#') return null;
	if (start + 1 >= line.len) return null;

	if (line[start + 1] == '"' and prefix != '#') {
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

fn hasDefinition(index: *const symbols.Index, kind: symbols.SymbolKind, name: []const u8, scope: ?[]const u8) bool {
	return findSymbol(index, kind, name, scope) != null;
}

fn findSymbol(index: *const symbols.Index, kind: symbols.SymbolKind, name: []const u8, scope: ?[]const u8) ?symbols.Symbol {
	for (index.symbols.items) |sym| {
		if (sym.kind != kind) continue;
		if (!std.mem.eql(u8, sym.name, name)) continue;
		if (!scopeEqual(sym.scope_function, scope)) continue;
		return sym;
	}
	return null;
}

fn scopeEqual(a: ?[]const u8, b: ?[]const u8) bool {
	if (a == null and b == null) return true;
	if (a == null or b == null) return false;
	return std.mem.eql(u8, a.?, b.?);
}
