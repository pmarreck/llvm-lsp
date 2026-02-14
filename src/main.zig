const builtin = @import("builtin");
const std = @import("std");
const parser = @import("core/parser.zig");
const symbols = @import("core/symbols.zig");

const max_message_bytes = 10 * 1024 * 1024;
const max_session_bytes = 64 * 1024 * 1024;

const Document = struct {
	source: []const u8,
	index: symbols.Index,
};

const SymbolQuery = struct {
	name: []const u8,
	scope: ?[]const u8,
	kind: enum {
		prefixed,
		label,
	},
	prefix: u8,
};

const TokenAtPosition = struct {
	token: []const u8,
	line_text: []const u8,
	line_number_1: usize,
	start: usize,
	end: usize,
	prefix: u8,
};

const Position = struct {
	line: usize,
	character: usize,
};

const ParseToken = struct {
	token: []const u8,
	next_index: usize,
};

pub fn main() !void {
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	defer _ = gpa.deinit();
	const allocator = gpa.allocator();

	var stdout_buffer: [4096]u8 = undefined;
	var stdout_file_writer = std.fs.File.stdout().writer(&stdout_buffer);
	const stdout = &stdout_file_writer.interface;

	var stderr_buffer: [4096]u8 = undefined;
	var stderr_file_writer = std.fs.File.stderr().writer(&stderr_buffer);
	const stderr = &stderr_file_writer.interface;

	if (comptime builtin.mode == .Debug) {
		try stderr.writeAll("\x1b[33mDEBUG BUILD\x1b[0m\n");
	}

	const exit_code = try run(allocator, stdout, stderr);

	try stdout.flush();
	try stderr.flush();

	if (exit_code != 0) {
		std.process.exit(exit_code);
	}
}

fn run(allocator: std.mem.Allocator, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !u8 {
	_ = stderr;

	const input = try std.fs.File.stdin().readToEndAlloc(allocator, max_session_bytes);
	defer allocator.free(input);

	var documents: std.StringHashMapUnmanaged(Document) = .{};
	defer deinitDocuments(allocator, &documents);

	if (input.len == 0) {
		return 0;
	}

	var saw_shutdown = false;
	var index: usize = 0;
	while (true) {
		const body_opt = parseNextFrame(input, &index) catch |err| {
			const message = switch (err) {
				error.InvalidCharacter, error.Overflow, error.MissingContentLength, error.InvalidFrame, error.TruncatedBody, error.MessageTooLarge => "invalid request framing",
			};
			try writeJsonRpcError(stdout, null, -32600, message);
			return 1;
		};
		if (body_opt == null) {
			break;
		}

		const body = body_opt.?;
		var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
			try writeJsonRpcError(stdout, null, -32700, "parse error");
			continue;
		};
		defer parsed.deinit();

		const root = parsed.value;
		const request_id = getRequestId(root);
		const method = getMethod(root) orelse {
			if (request_id != null) {
				try writeJsonRpcError(stdout, request_id, -32600, "invalid request");
			}
			continue;
		};

		if (std.mem.eql(u8, method, "initialize")) {
			const id = request_id orelse continue;
			try writeJsonRpcResult(
				allocator,
				stdout,
				id,
				"{\"capabilities\":{\"definitionProvider\":true,\"referencesProvider\":true,\"documentSymbolProvider\":true,\"hoverProvider\":true,\"completionProvider\":{\"triggerCharacters\":[\"@\",\"%\",\"!\"]},\"textDocumentSync\":1}}",
			);
			continue;
		}

		if (std.mem.eql(u8, method, "initialized")) {
			continue;
		}

		if (std.mem.eql(u8, method, "textDocument/didOpen")) {
			handleDidOpen(allocator, &documents, root) catch {
				if (request_id != null) {
					try writeJsonRpcError(stdout, request_id, -32600, "invalid request");
				}
				continue;
			};
			try publishDiagnosticsForRequest(allocator, stdout, &documents, root);
			continue;
		}

		if (std.mem.eql(u8, method, "textDocument/didChange")) {
			handleDidChange(allocator, &documents, root) catch {
				if (request_id != null) {
					try writeJsonRpcError(stdout, request_id, -32600, "invalid request");
				}
				continue;
			};
			try publishDiagnosticsForRequest(allocator, stdout, &documents, root);
			continue;
		}

		if (std.mem.eql(u8, method, "textDocument/didClose")) {
			const closed_uri = extractUriFromLifecycleRequest(root);
			handleDidClose(allocator, &documents, root) catch {
				if (request_id != null) {
					try writeJsonRpcError(stdout, request_id, -32600, "invalid request");
				}
				continue;
			};
			if (closed_uri) |uri| {
				const params_json = try std.fmt.allocPrint(allocator, "{{\"uri\":\"{s}\",\"diagnostics\":[]}}", .{uri});
				defer allocator.free(params_json);
				try writeJsonRpcNotification(
					allocator,
					stdout,
					"textDocument/publishDiagnostics",
					params_json,
				);
			}
			continue;
		}

		if (std.mem.eql(u8, method, "textDocument/definition")) {
			const id = request_id orelse continue;
			const result = handleDefinition(allocator, &documents, root) catch {
				try writeJsonRpcError(stdout, id, -32600, "invalid request");
				continue;
			};
			defer allocator.free(result);
			try writeJsonRpcResult(allocator, stdout, id, result);
			continue;
		}

		if (std.mem.eql(u8, method, "textDocument/references")) {
			const id = request_id orelse continue;
			const result = handleReferences(allocator, &documents, root) catch {
				try writeJsonRpcError(stdout, id, -32600, "invalid request");
				continue;
			};
			defer allocator.free(result);
			try writeJsonRpcResult(allocator, stdout, id, result);
			continue;
		}

		if (std.mem.eql(u8, method, "textDocument/documentSymbol")) {
			const id = request_id orelse continue;
			const result = handleDocumentSymbol(allocator, &documents, root) catch {
				try writeJsonRpcError(stdout, id, -32600, "invalid request");
				continue;
			};
			defer allocator.free(result);
			try writeJsonRpcResult(allocator, stdout, id, result);
			continue;
		}

		if (std.mem.eql(u8, method, "textDocument/hover")) {
			const id = request_id orelse continue;
			const result = handleHover(allocator, &documents, root) catch {
				try writeJsonRpcError(stdout, id, -32600, "invalid request");
				continue;
			};
			defer allocator.free(result);
			try writeJsonRpcResult(allocator, stdout, id, result);
			continue;
		}

		if (std.mem.eql(u8, method, "textDocument/completion")) {
			const id = request_id orelse continue;
			const result = handleCompletion(allocator, &documents, root) catch {
				try writeJsonRpcError(stdout, id, -32600, "invalid request");
				continue;
			};
			defer allocator.free(result);
			try writeJsonRpcResult(allocator, stdout, id, result);
			continue;
		}

		if (std.mem.eql(u8, method, "shutdown")) {
			saw_shutdown = true;
			const id = request_id orelse continue;
			try writeJsonRpcResult(allocator, stdout, id, "null");
			continue;
		}

		if (std.mem.eql(u8, method, "exit")) {
			return if (saw_shutdown) 0 else 1;
		}

		if (request_id != null) {
			try writeJsonRpcError(stdout, request_id, -32601, "method not found");
		}
	}

	return 0;
}

fn handleDidOpen(allocator: std.mem.Allocator, documents: *std.StringHashMapUnmanaged(Document), root: std.json.Value) !void {
	const params = getField(root, "params") orelse return error.InvalidRequest;
	const text_document = getField(params, "textDocument") orelse return error.InvalidRequest;
	const uri = getStringField(text_document, "uri") orelse return error.InvalidRequest;
	const text = getStringField(text_document, "text") orelse return error.InvalidRequest;
	try upsertDocument(allocator, documents, uri, text);
}

fn handleDidChange(allocator: std.mem.Allocator, documents: *std.StringHashMapUnmanaged(Document), root: std.json.Value) !void {
	const params = getField(root, "params") orelse return error.InvalidRequest;
	const text_document = getField(params, "textDocument") orelse return error.InvalidRequest;
	const uri = getStringField(text_document, "uri") orelse return error.InvalidRequest;
	const changes = getField(params, "contentChanges") orelse return error.InvalidRequest;
	const new_text = switch (changes) {
		.array => |arr| blk: {
			if (arr.items.len == 0) return error.InvalidRequest;
			const first = arr.items[0];
			const text = getStringField(first, "text") orelse return error.InvalidRequest;
			break :blk text;
		},
		else => return error.InvalidRequest,
	};
	try upsertDocument(allocator, documents, uri, new_text);
}

fn handleDidClose(allocator: std.mem.Allocator, documents: *std.StringHashMapUnmanaged(Document), root: std.json.Value) !void {
	const params = getField(root, "params") orelse return error.InvalidRequest;
	const text_document = getField(params, "textDocument") orelse return error.InvalidRequest;
	const uri = getStringField(text_document, "uri") orelse return error.InvalidRequest;
	removeDocument(allocator, documents, uri);
}

fn handleDefinition(allocator: std.mem.Allocator, documents: *std.StringHashMapUnmanaged(Document), root: std.json.Value) ![]u8 {
	const params = getField(root, "params") orelse return error.InvalidRequest;
	const text_document = getField(params, "textDocument") orelse return error.InvalidRequest;
	const uri = getStringField(text_document, "uri") orelse return error.InvalidRequest;
	const pos = parsePosition(params) orelse return error.InvalidRequest;

	const doc = documents.getPtr(uri) orelse return allocator.dupe(u8, "null");
	const token = resolveTokenAt(doc.source, pos.line, pos.character) orelse return allocator.dupe(u8, "null");
	const query = classifyQuery(doc, token) orelse return allocator.dupe(u8, "null");
	const definition = findDefinitionSymbol(&doc.index, query) orelse return allocator.dupe(u8, "null");

	const result = try std.fmt.allocPrint(
		allocator,
		"{{\"uri\":\"{s}\",\"range\":{{\"start\":{{\"line\":{d},\"character\":0}},\"end\":{{\"line\":{d},\"character\":{d}}}}}}}",
		.{ uri, definition.line - 1, definition.line - 1, definition.name.len },
	);
	return result;
}

fn handleReferences(allocator: std.mem.Allocator, documents: *std.StringHashMapUnmanaged(Document), root: std.json.Value) ![]u8 {
	const params = getField(root, "params") orelse return error.InvalidRequest;
	const text_document = getField(params, "textDocument") orelse return error.InvalidRequest;
	const uri = getStringField(text_document, "uri") orelse return error.InvalidRequest;
	const pos = parsePosition(params) orelse return error.InvalidRequest;
	const include_declaration = parseIncludeDeclaration(params) orelse false;

	const doc = documents.getPtr(uri) orelse return allocator.dupe(u8, "[]");
	const token = resolveTokenAt(doc.source, pos.line, pos.character) orelse return allocator.dupe(u8, "[]");
	const query = classifyQuery(doc, token) orelse return allocator.dupe(u8, "[]");

	var out: std.ArrayListUnmanaged(u8) = .{};
	errdefer out.deinit(allocator);
	try out.appendSlice(allocator, "[");
	var wrote_any = false;

	if (include_declaration) {
		if (findDefinitionSymbol(&doc.index, query)) |definition| {
			try appendLocationJson(allocator, &out, &wrote_any, uri, definition.line - 1, definition.name.len);
		}
	}

	for (doc.index.references.items) |reference| {
		if (!std.mem.eql(u8, reference.name, query.name)) continue;
		if (!scopeEqual(reference.scope_function, query.scope)) continue;
		try appendLocationJson(allocator, &out, &wrote_any, uri, reference.line - 1, reference.name.len);
	}

	try out.appendSlice(allocator, "]");
	return try out.toOwnedSlice(allocator);
}

fn handleDocumentSymbol(allocator: std.mem.Allocator, documents: *std.StringHashMapUnmanaged(Document), root: std.json.Value) ![]u8 {
	const params = getField(root, "params") orelse return error.InvalidRequest;
	const text_document = getField(params, "textDocument") orelse return error.InvalidRequest;
	const uri = getStringField(text_document, "uri") orelse return error.InvalidRequest;
	const doc = documents.getPtr(uri) orelse return allocator.dupe(u8, "[]");

	var out: std.ArrayListUnmanaged(u8) = .{};
	errdefer out.deinit(allocator);
	try out.appendSlice(allocator, "[");
	var wrote_any = false;

	for (doc.index.symbols.items) |symbol| {
		const kind_value_opt = switch (symbol.kind) {
			.function_def, .function_decl => @as(u8, 12),
			.global => @as(u8, 13),
			.type_alias => @as(u8, 23),
			.metadata => @as(u8, 19),
			else => null,
		};
		if (kind_value_opt == null) continue;
		const kind_value = kind_value_opt.?;
		const line_index = if (symbol.line == 0) 0 else symbol.line - 1;
		const line_text = getLineAt(doc.source, line_index) orelse "";
		const trimmed_line = std.mem.trim(u8, line_text, " \t\r");
		const range_end = trimmed_line.len;
		const selection_start = findSelectionStartInLine(line_text, symbol.name) orelse 0;
		const selection_end = selection_start + symbol.name.len;

		if (wrote_any) {
			try out.appendSlice(allocator, ",");
		}
		wrote_any = true;

		const piece = try std.fmt.allocPrint(
			allocator,
			"{{\"name\":\"{s}\",\"kind\":{d},\"range\":{{\"start\":{{\"line\":{d},\"character\":0}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"selectionRange\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}}}",
			.{
				symbol.name,
				kind_value,
				line_index,
				line_index,
				range_end,
				line_index,
				selection_start,
				line_index,
				selection_end,
			},
		);
		defer allocator.free(piece);
		try out.appendSlice(allocator, piece);
	}

	try out.appendSlice(allocator, "]");
	return try out.toOwnedSlice(allocator);
}

fn publishDiagnosticsForRequest(allocator: std.mem.Allocator, stdout: *std.Io.Writer, documents: *std.StringHashMapUnmanaged(Document), root: std.json.Value) !void {
	const uri = extractUriFromLifecycleRequest(root) orelse return;
	const doc = documents.getPtr(uri) orelse return;
	const params_json = try buildDiagnosticsParamsJson(allocator, uri, doc);
	defer allocator.free(params_json);
	try writeJsonRpcNotification(allocator, stdout, "textDocument/publishDiagnostics", params_json);
}

fn extractUriFromLifecycleRequest(root: std.json.Value) ?[]const u8 {
	const params = getField(root, "params") orelse return null;
	const text_document = getField(params, "textDocument") orelse return null;
	return getStringField(text_document, "uri");
}

fn buildDiagnosticsParamsJson(allocator: std.mem.Allocator, uri: []const u8, doc: *const Document) ![]u8 {
	var out: std.ArrayListUnmanaged(u8) = .{};
	errdefer out.deinit(allocator);
	try out.appendSlice(allocator, "{\"uri\":\"");
	try out.appendSlice(allocator, uri);
	try out.appendSlice(allocator, "\",\"diagnostics\":[");
	var wrote_any = false;

	for (doc.index.references.items) |reference| {
		if (reference.name.len == 0 or reference.name[0] != '%') continue;
		const scope = reference.scope_function orelse continue;
		if (reference.name.len > 1 and hasDefinition(&doc.index, .label, reference.name[1..], scope)) continue;
		if (hasDefinition(&doc.index, .local, reference.name, scope)) continue;
		if (hasDefinition(&doc.index, .param, reference.name, scope)) continue;
		if (hasDefinition(&doc.index, .type_alias, reference.name, null)) continue;

		const message = try std.fmt.allocPrint(allocator, "undefined symbol {s}", .{reference.name});
		defer allocator.free(message);
		try appendDiagnostic(allocator, &out, &wrote_any, reference.line - 1, reference.name.len, 1, message);
	}

	var i: usize = 0;
	while (i < doc.index.symbols.items.len) : (i += 1) {
		const symbol = doc.index.symbols.items[i];
		if (!isDuplicateCheckedKind(symbol.kind)) continue;

		var seen_before = false;
		var j: usize = 0;
		while (j < i) : (j += 1) {
			const previous = doc.index.symbols.items[j];
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
	var lines = std.mem.splitScalar(u8, doc.source, '\n');
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

fn handleHover(allocator: std.mem.Allocator, documents: *std.StringHashMapUnmanaged(Document), root: std.json.Value) ![]u8 {
	const params = getField(root, "params") orelse return error.InvalidRequest;
	const text_document = getField(params, "textDocument") orelse return error.InvalidRequest;
	const uri = getStringField(text_document, "uri") orelse return error.InvalidRequest;
	const pos = parsePosition(params) orelse return error.InvalidRequest;

	const doc = documents.getPtr(uri) orelse return allocator.dupe(u8, "null");
	if (resolveTokenAt(doc.source, pos.line, pos.character)) |token| {
		const query = classifyQuery(doc, token) orelse return allocator.dupe(u8, "null");
		const definition = findDefinitionSymbol(&doc.index, query) orelse return allocator.dupe(u8, "null");
		const kind_name = switch (definition.kind) {
			.function_def, .function_decl => "function",
			.global => "global",
			.type_alias => "type alias",
			.local, .param => "local",
			.label => "label",
			.metadata => "metadata",
		};
		const maybe_line = getLineAt(doc.source, definition.line - 1);
		const content = if (maybe_line) |line|
			try std.fmt.allocPrint(
				allocator,
				"`{s}` {s} (from: {s})",
				.{ definition.name, kind_name, std.mem.trim(u8, line, " \t\r") },
			)
		else
			try std.fmt.allocPrint(allocator, "`{s}` {s}", .{ definition.name, kind_name });
		defer allocator.free(content);

		return try std.fmt.allocPrint(
			allocator,
			"{{\"contents\":{{\"kind\":\"markdown\",\"value\":\"{s}\"}}}}",
			.{content},
		);
	}

	if (resolveOpcodeHover(pos, doc.source)) |description| {
		return try std.fmt.allocPrint(
			allocator,
			"{{\"contents\":{{\"kind\":\"markdown\",\"value\":\"{s}\"}}}}",
			.{description},
		);
	}

	return allocator.dupe(u8, "null");
}

fn handleCompletion(allocator: std.mem.Allocator, documents: *std.StringHashMapUnmanaged(Document), root: std.json.Value) ![]u8 {
	const params = getField(root, "params") orelse return error.InvalidRequest;
	const text_document = getField(params, "textDocument") orelse return error.InvalidRequest;
	const uri = getStringField(text_document, "uri") orelse return error.InvalidRequest;
	const pos = parsePosition(params) orelse return error.InvalidRequest;

	const doc = documents.getPtr(uri) orelse return allocator.dupe(u8, "[]");
	const line = getLineAt(doc.source, pos.line) orelse return allocator.dupe(u8, "[]");
	if (pos.character == 0 or pos.character > line.len) return allocator.dupe(u8, "[]");

	const trigger = line[pos.character - 1];
	var labels: std.StringHashMapUnmanaged(void) = .{};
	defer labels.deinit(allocator);

	const scope = inferFunctionScopeForLine(&doc.index, pos.line + 1);
	var handled_trigger = false;
	const label_completion_context = isLabelCompletionContext(line, pos.character);

	for (doc.index.symbols.items) |sym| {
		switch (trigger) {
			'@' => switch (sym.kind) {
				.function_def, .function_decl, .global => {
					if (sym.name.len > 0 and sym.name[0] == '@') {
						try labels.put(allocator, sym.name, {});
					}
					handled_trigger = true;
				},
				else => {},
			},
				'%' => switch (sym.kind) {
					.label => {
						if (label_completion_context and scopeEqual(sym.scope_function, scope)) {
							try labels.put(allocator, sym.name, {});
							handled_trigger = true;
						}
					},
					.local, .param => {
						if (!label_completion_context and scopeEqual(sym.scope_function, scope)) {
							try labels.put(allocator, sym.name, {});
							handled_trigger = true;
						}
					},
					.type_alias => {
						if (!label_completion_context) {
							try labels.put(allocator, sym.name, {});
							handled_trigger = true;
						}
					},
					else => {},
				},
			'!' => switch (sym.kind) {
				.metadata => {
					try labels.put(allocator, sym.name, {});
					handled_trigger = true;
				},
				else => {},
			},
			else => {},
		}
	}

	if (!handled_trigger) {
		const before_cursor = line[0..pos.character];
		if (std.mem.endsWith(u8, before_cursor, "= ")) {
			try appendStaticCompletions(allocator, &labels, &.{
				"alloca",
				"load",
				"store",
				"add",
				"sub",
				"mul",
				"call",
				"ret",
				"br",
			});
		} else if (endsWithOpcodeSpace(before_cursor)) {
			try appendStaticCompletions(allocator, &labels, &.{
				"i1",
				"i8",
				"i16",
				"i32",
				"i64",
				"ptr",
				"void",
			});
		}
	}

	var out: std.ArrayListUnmanaged(u8) = .{};
	errdefer out.deinit(allocator);
	try out.appendSlice(allocator, "[");
	var wrote_any = false;

	var it = labels.iterator();
	while (it.next()) |entry| {
		if (wrote_any) {
			try out.appendSlice(allocator, ",");
		}
		wrote_any = true;
		const piece = try std.fmt.allocPrint(
			allocator,
			"{{\"label\":\"{s}\"}}",
			.{entry.key_ptr.*},
		);
		defer allocator.free(piece);
		try out.appendSlice(allocator, piece);
	}

	try out.appendSlice(allocator, "]");
	return try out.toOwnedSlice(allocator);
}

fn appendStaticCompletions(allocator: std.mem.Allocator, labels: *std.StringHashMapUnmanaged(void), values: []const []const u8) !void {
	for (values) |value| {
		try labels.put(allocator, value, {});
	}
}

fn endsWithOpcodeSpace(before_cursor: []const u8) bool {
	return std.mem.endsWith(u8, before_cursor, "add ") or
		std.mem.endsWith(u8, before_cursor, "sub ") or
		std.mem.endsWith(u8, before_cursor, "mul ") or
		std.mem.endsWith(u8, before_cursor, "load ") or
		std.mem.endsWith(u8, before_cursor, "store ") or
		std.mem.endsWith(u8, before_cursor, "call ") or
		std.mem.endsWith(u8, before_cursor, "ret ") or
		std.mem.endsWith(u8, before_cursor, "br ") or
		std.mem.endsWith(u8, before_cursor, "alloca ");
}

fn isLabelCompletionContext(line: []const u8, character: usize) bool {
	if (character == 0 or character > line.len) return false;
	const before_cursor = line[0..character];
	return std.mem.endsWith(u8, before_cursor, "label %");
}

fn resolveOpcodeHover(pos: Position, source: []const u8) ?[]const u8 {
	const line = getLineAt(source, pos.line) orelse return null;
	const word = getWordAtPosition(line, pos.character) orelse return null;
	return switchOpcodeHover(word);
}

fn getWordAtPosition(line: []const u8, character: usize) ?[]const u8 {
	if (line.len == 0) return null;
	const cursor = if (character >= line.len) line.len - 1 else character;
	if (!isWordChar(line[cursor])) return null;

	var start = cursor;
	while (start > 0 and isWordChar(line[start - 1])) : (start -= 1) {}

	var end = cursor + 1;
	while (end < line.len and isWordChar(line[end])) : (end += 1) {}

	if (end <= start) return null;
	return line[start..end];
}

fn isWordChar(c: u8) bool {
	return std.ascii.isAlphabetic(c);
}

fn switchOpcodeHover(word: []const u8) ?[]const u8 {
	if (std.mem.eql(u8, word, "ret")) return "Return from function";
	if (std.mem.eql(u8, word, "br")) return "Branch to target label";
	if (std.mem.eql(u8, word, "add")) return "Integer addition";
	if (std.mem.eql(u8, word, "store")) return "Store a value to memory";
	if (std.mem.eql(u8, word, "load")) return "Load a value from memory";
	if (std.mem.eql(u8, word, "call")) return "Call a function";
	if (std.mem.eql(u8, word, "alloca")) return "Allocate stack memory";
	return null;
}

fn appendLocationJson(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), wrote_any: *bool, uri: []const u8, line: usize, name_len: usize) !void {
	if (wrote_any.*) {
		try out.appendSlice(allocator, ",");
	}
	wrote_any.* = true;
	const piece = try std.fmt.allocPrint(
		allocator,
		"{{\"uri\":\"{s}\",\"range\":{{\"start\":{{\"line\":{d},\"character\":0}},\"end\":{{\"line\":{d},\"character\":{d}}}}}}}",
		.{ uri, line, line, name_len },
	);
	defer allocator.free(piece);
	try out.appendSlice(allocator, piece);
}

fn classifyQuery(doc: *const Document, token: TokenAtPosition) ?SymbolQuery {
	if (token.prefix == '%') {
		const scope = inferFunctionScopeForLine(&doc.index, token.line_number_1);
		if (isLabelContext(token.line_text, token.start)) {
			if (token.token.len <= 1) return null;
			return .{
				.name = token.token[1..],
				.scope = scope,
				.kind = .label,
				.prefix = token.prefix,
			};
		}

		if (scope != null and (hasDefinition(&doc.index, .local, token.token, scope) or hasDefinition(&doc.index, .param, token.token, scope))) {
			return .{
				.name = token.token,
				.scope = scope,
				.kind = .prefixed,
				.prefix = token.prefix,
			};
		}

		if (hasDefinition(&doc.index, .type_alias, token.token, null)) {
			return .{
				.name = token.token,
				.scope = null,
				.kind = .prefixed,
				.prefix = token.prefix,
			};
		}

		return .{
			.name = token.token,
			.scope = scope,
			.kind = .prefixed,
			.prefix = token.prefix,
		};
	}

	return .{
		.name = token.token,
		.scope = null,
		.kind = .prefixed,
		.prefix = token.prefix,
	};
}

fn findDefinitionSymbol(index: *const symbols.Index, query: SymbolQuery) ?symbols.Symbol {
	if (query.kind == .label) {
		return findSymbol(index, .label, query.name, query.scope);
	}

	switch (query.prefix) {
		'@' => {
			if (findSymbol(index, .function_def, query.name, null)) |sym| return sym;
			if (findSymbol(index, .function_decl, query.name, null)) |sym| return sym;
			if (findSymbol(index, .global, query.name, null)) |sym| return sym;
			return null;
		},
		'%' => {
			if (findSymbol(index, .local, query.name, query.scope)) |sym| return sym;
			if (findSymbol(index, .param, query.name, query.scope)) |sym| return sym;
			if (findSymbol(index, .type_alias, query.name, null)) |sym| return sym;
			return null;
		},
		'!' => return findSymbol(index, .metadata, query.name, null),
		'#' => return null,
		else => return null,
	}
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

fn hasDefinition(index: *const symbols.Index, kind: symbols.SymbolKind, name: []const u8, scope: ?[]const u8) bool {
	return findSymbol(index, kind, name, scope) != null;
}

fn inferFunctionScopeForLine(index: *const symbols.Index, line_number_1: usize) ?[]const u8 {
	var best: ?[]const u8 = null;
	var best_line: usize = 0;
	for (index.symbols.items) |sym| {
		if (sym.kind != .function_def) continue;
		if (sym.line > line_number_1) continue;
		if (sym.line >= best_line) {
			best_line = sym.line;
			best = sym.name;
		}
	}
	return best;
}

fn isLabelContext(line: []const u8, token_start: usize) bool {
	if (token_start == 0) return false;
	const prefix = std.mem.trimRight(u8, line[0..token_start], " \t,");
	return std.mem.endsWith(u8, prefix, "label");
}

fn resolveTokenAt(source: []const u8, line_index: usize, character: usize) ?TokenAtPosition {
	const line_opt = getLineAt(source, line_index);
	if (line_opt == null) return null;
	const line = line_opt.?;
	if (line.len == 0) return null;

	var cursor: usize = 0;
	while (cursor < line.len) {
		const c = line[cursor];
		if (c != '%' and c != '@' and c != '!' and c != '#') {
			cursor += 1;
			continue;
		}
		const parsed = parsePrefixedTokenAt(line, cursor) orelse {
			cursor += 1;
			continue;
		};
		if (character >= cursor and character < parsed.next_index) {
			return .{
				.token = parsed.token,
				.line_text = line,
				.line_number_1 = line_index + 1,
				.start = cursor,
				.end = parsed.next_index,
				.prefix = c,
			};
		}
		cursor = parsed.next_index;
	}
	return null;
}

fn getLineAt(source: []const u8, line_index: usize) ?[]const u8 {
	var i: usize = 0;
	var lines = std.mem.splitScalar(u8, source, '\n');
	while (lines.next()) |line| {
		if (i == line_index) {
			return line;
		}
		i += 1;
	}
	return null;
}

fn findSelectionStartInLine(line: []const u8, token: []const u8) ?usize {
	return std.mem.indexOf(u8, line, token);
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

fn parsePosition(params: std.json.Value) ?Position {
	const position = getField(params, "position") orelse return null;
	const line_value = getIntegerField(position, "line") orelse return null;
	const character_value = getIntegerField(position, "character") orelse return null;
	if (line_value < 0 or character_value < 0) return null;
	return .{
		.line = @intCast(line_value),
		.character = @intCast(character_value),
	};
}

fn parseIncludeDeclaration(params: std.json.Value) ?bool {
	const context = getField(params, "context") orelse return null;
	const include = getField(context, "includeDeclaration") orelse return null;
	return switch (include) {
		.bool => |b| b,
		else => null,
	};
}

fn upsertDocument(allocator: std.mem.Allocator, documents: *std.StringHashMapUnmanaged(Document), uri: []const u8, text: []const u8) !void {
	const uri_copy = try allocator.dupe(u8, uri);
	errdefer allocator.free(uri_copy);
	const source_copy = try allocator.dupe(u8, text);
	errdefer allocator.free(source_copy);
	var index = try parser.parseModule(allocator, source_copy);
	errdefer index.deinit();

	removeDocument(allocator, documents, uri);
	try documents.put(allocator, uri_copy, .{
		.source = source_copy,
		.index = index,
	});
}

fn removeDocument(allocator: std.mem.Allocator, documents: *std.StringHashMapUnmanaged(Document), uri: []const u8) void {
	if (documents.*.fetchRemove(uri)) |removed| {
		var doc = removed.value;
		doc.index.deinit();
		allocator.free(doc.source);
		allocator.free(removed.key);
	}
}

fn deinitDocuments(allocator: std.mem.Allocator, documents: *std.StringHashMapUnmanaged(Document)) void {
	var it = documents.iterator();
	while (it.next()) |entry| {
		entry.value_ptr.index.deinit();
		allocator.free(entry.value_ptr.source);
		allocator.free(entry.key_ptr.*);
	}
	documents.deinit(allocator);
}

fn getMethod(root: std.json.Value) ?[]const u8 {
	const value = getField(root, "method") orelse return null;
	return switch (value) {
		.string => |s| s,
		else => null,
	};
}

fn getRequestId(root: std.json.Value) ?i64 {
	const value = getField(root, "id") orelse return null;
	return switch (value) {
		.integer => |i| i,
		else => null,
	};
}

fn getField(root: std.json.Value, key: []const u8) ?std.json.Value {
	return switch (root) {
		.object => |obj| obj.get(key),
		else => null,
	};
}

fn getStringField(root: std.json.Value, key: []const u8) ?[]const u8 {
	const value = getField(root, key) orelse return null;
	return switch (value) {
		.string => |s| s,
		else => null,
	};
}

fn getIntegerField(root: std.json.Value, key: []const u8) ?i64 {
	const value = getField(root, key) orelse return null;
	return switch (value) {
		.integer => |i| i,
		else => null,
	};
}

fn scopeEqual(a: ?[]const u8, b: ?[]const u8) bool {
	if (a == null and b == null) return true;
	if (a == null or b == null) return false;
	return std.mem.eql(u8, a.?, b.?);
}

fn parseNextFrame(input: []const u8, index: *usize) !?[]const u8 {
	while (index.* < input.len and (input[index.*] == '\n' or input[index.*] == '\r')) {
		index.* += 1;
	}

	if (index.* >= input.len) {
		return null;
	}

	const header_end = std.mem.indexOfPos(u8, input, index.*, "\r\n\r\n") orelse return error.InvalidFrame;
	const header = input[index.*..header_end];

	var content_length: ?usize = null;
	var lines = std.mem.splitSequence(u8, header, "\r\n");
	while (lines.next()) |line| {
		if (!std.mem.startsWith(u8, line, "Content-Length:")) {
			continue;
		}
		const len_text = std.mem.trim(u8, line["Content-Length:".len..], " \t");
		content_length = try std.fmt.parseInt(usize, len_text, 10);
	}

	const body_len = content_length orelse return error.MissingContentLength;
	if (body_len > max_message_bytes) {
		return error.MessageTooLarge;
	}
	const body_start = header_end + 4;
	const body_end = body_start + body_len;
	if (body_end > input.len) {
		return error.TruncatedBody;
	}

	index.* = body_end;
	return input[body_start..body_end];
}

fn writeFramed(stdout: *std.Io.Writer, body: []const u8) !void {
	try stdout.print("Content-Length: {d}\r\n\r\n", .{body.len});
	try stdout.writeAll(body);
}

fn writeJsonRpcResult(allocator: std.mem.Allocator, stdout: *std.Io.Writer, id: i64, result_json: []const u8) !void {
	const body = try std.fmt.allocPrint(
		allocator,
		"{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{s}}}",
		.{ id, result_json },
	);
	defer allocator.free(body);
	try writeFramed(stdout, body);
}

fn writeJsonRpcNotification(allocator: std.mem.Allocator, stdout: *std.Io.Writer, method: []const u8, params_json: []const u8) !void {
	const body = try std.fmt.allocPrint(
		allocator,
		"{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\",\"params\":{s}}}",
		.{ method, params_json },
	);
	defer allocator.free(body);
	try writeFramed(stdout, body);
}

fn writeJsonRpcError(stdout: *std.Io.Writer, id: ?i64, code: i64, message: []const u8) !void {
	if (id) |value| {
		var buffer: [256]u8 = undefined;
		const body = try std.fmt.bufPrint(
			&buffer,
			"{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":{d},\"message\":\"{s}\"}}}}",
			.{ value, code, message },
		);
		try writeFramed(stdout, body);
		return;
	}

	var buffer: [256]u8 = undefined;
	const body = try std.fmt.bufPrint(
		&buffer,
		"{{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{{\"code\":{d},\"message\":\"{s}\"}}}}",
		.{ code, message },
	);
	try writeFramed(stdout, body);
}
