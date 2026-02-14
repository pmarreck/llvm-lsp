# llvm-lsp Specification

Status: Draft v1.0 (2026-02-14 EST)
Owner: Peter Marreck
Target branch: `yolo`

## 1. Goal

Build a fast, dependency-free Language Server Protocol (LSP) server for LLVM IR text files (`.ll`) written in Zig, delivered as a single binary.

Primary value:
- Navigate SSA-heavy IR quickly (`definition`, `references`, `hover`).
- Catch obvious IR authoring mistakes early (`diagnostics`).
- Keep developer loop fast on large generated IR files.

## 2. Done Criteria (Release 0.1)

Release `0.1.0` is done when all items below are true:
- Binary `llvm-lsp` handles core LSP lifecycle: `initialize`, `initialized`, `shutdown`, `exit`.
- Supports `didOpen`, `didChange` (full sync), `didClose`.
- Supports `documentSymbol`, `definition`, `references`, `hover`, `completion`.
- Publishes diagnostics on parse and symbol resolution failures.
- Operates correctly on `.ll` files up to 10 MB.
- No runtime dependency on LLVM shared libraries.
- `./build`, `./test` scripts exist and succeed in clean checkout.
- Full test suite passes in CI and locally with deterministic results.

## 3. Scope

In scope:
- LLVM IR textual syntax (`.ll`) only.
- Single-document analysis (no cross-module indexing in 0.1).
- JSON-RPC 2.0 over stdio with LSP framing.

Out of scope:
- `.bc` bitcode parsing.
- Semantic refactors (rename/code actions/formatting).
- Control-flow graph visualization.
- Full type verifier parity with `opt -verify`.

## 4. Users and Workflows

Users:
- Compiler engineers reading generated IR.
- Performance engineers tracing value flow.
- Tooling developers integrating with editors or `codescan`.

Core workflows:
- Jump from use (`%x`) to defining instruction.
- Find all uses of a local/global/type symbol.
- Hover symbol/opcode for quick context.
- Get diagnostics while editing malformed IR.
- Get completions for opcodes, types, and in-scope symbols.

## 5. Functional Requirements

### 5.1 LSP Transport

Required behavior:
- Parse/write `Content-Length` framed messages over stdin/stdout.
- Reject message bodies larger than 10 MB with JSON-RPC error.
- Never write logs to stdout; logs go to stderr only.
- Exit code rules:
- `0` after `shutdown` then `exit`.
- `1` on `exit` without prior `shutdown`.

### 5.2 Document Lifecycle

Required behavior:
- `didOpen`: parse and index document.
- `didChange`: replace text and reparse (full sync only in 0.1).
- `didClose`: remove document and free owned memory.

### 5.3 Language Features

`textDocument/documentSymbol`:
- Return functions, globals, type aliases, metadata nodes.

`textDocument/definition`:
- Resolve `%local`, `@global`, `%type_alias`, metadata IDs, block labels.
- Return null for unknown tokens/keywords/literals.

`textDocument/references`:
- Return all use sites for resolved symbol in correct scope.
- Local symbols are function-scoped; same local name in another function is distinct.

`textDocument/hover`:
- Show symbol type + defining context.
- Show opcode summary for common LLVM instructions.

`textDocument/completion`:
- `%` prefix: in-scope locals and type aliases.
- `@` prefix: globals and function names.
- `!` prefix: metadata IDs.
- After assignment (`%x = `): instruction opcode suggestions.
- After opcode: type suggestions (`i1`, `i8`, `i32`, `i64`, `ptr`, `void`).

### 5.4 Diagnostics

Required diagnostics:
- Parse errors (unexpected/malformed tokens).
- Undefined symbol uses.
- Duplicate definitions in invalid scope.
- Basic block missing terminator.

Severity mapping:
- Error: parse, undefined symbol, duplicate definition, missing terminator.
- Warning: suspicious but parseable constructs reserved for later verifier checks.

## 6. LLVM IR Support Envelope (0.1)

Must parse/index:
- Module headers (`source_filename`, `target triple`, `target datalayout`).
- Global declarations/definitions.
- Function declarations and definitions.
- Basic block labels.
- Local/global identifiers and numbered SSA names.
- Named type aliases.
- Metadata node references (`!N`) and named metadata labels.

Best-effort in 0.1:
- Complex constant expressions.
- Exotic attributes and calling conventions.

## 7. Architecture

Design constraints:
- Hexagonal style: pure core + thin I/O adapter.
- Core must be usable without LSP runtime (library-first design).
- Single-threaded event loop in 0.1 (add concurrency only if profiling requires it).

Target module layout:
- `src/main.zig`: process entry, lifecycle, logging setup.
- `src/transport.zig`: framed message read/write.
- `src/server.zig`: LSP dispatch + document state.
- `src/core/lexer.zig`: token stream over source slices.
- `src/core/parser.zig`: tolerant parser + symbol/use extraction.
- `src/core/symbols.zig`: symbol tables and lookup queries.
- `src/core/diagnostics.zig`: deterministic diagnostic generation.

Memory model:
- Per-document arena allocator.
- Reparse replaces arena wholesale for document simplicity/safety.

## 8. Non-Functional Requirements

Performance targets:
- Open+parse 10k-line IR file: <= 500 ms on dev laptop baseline.
- Definition query on indexed file: <= 50 ms.
- References query on indexed file: <= 100 ms.
- Completion query on indexed file: <= 100 ms.
- Peak memory per 10 MB document: <= 64 MB.

Reliability:
- No panics on malformed input.
- Parser must recover and continue to next top-level entity when possible.

Security posture:
- Treat file content as untrusted input.
- Hard caps on message and file sizes.
- No shell execution in core functionality.

## 9. Test Strategy (TDD-First)

Rules:
- Every new behavior starts with a failing test.
- Minimal implementation to green, then refactor.
- Deterministic tests only (no sleeps/time races).

Test layout:
- `tests/unit`: lexer/parser/symbol/diagnostic behavior.
- `tests/integration`: LSP request/response sessions.
- `tests/cli`: binary lifecycle and stdio framing scripts.

Project scripts:
- `./build`: optimized build by default (`ReleaseFast`), supports `--test` and `--debug`.
- `./test`: runs all non-benchmark, non-fuzz suites and returns aggregate failure code.
- Optional later: `./bm`, `./fuzz`.

## 10. Milestones

M0 Foundation:
- Build system, scripts, binary skeleton, LSP lifecycle.
- Curiosity poke: framing edge cases (partial headers, malformed lengths).

M1 Parsing core:
- Lexer + tolerant parser + symbol table + source spans.
- Curiosity poke: scope collisions (`%0` reuse across functions).

M2 Navigation:
- `documentSymbol`, `definition`, `references`.
- Curiosity poke: label references in nested/branch-heavy blocks.

M3 Authoring assist:
- `hover`, `completion`, diagnostics publication.
- Curiosity poke: false-positive diagnostics on incomplete edits.

M4 Hardening:
- Stress tests with large and malformed corpora.
- Curiosity poke: memory stability across repeated `didChange`.

## 11. Acceptance Matrix

Release gate checks:
- `./build` succeeds on clean checkout.
- `./test` passes fully.
- Integration fixture validates end-to-end session for all supported LSP methods.
- Manual smoke in one editor client confirms basic navigation loop.
- Debug build prints visible `DEBUG BUILD` warning on stderr; release build does not.

## 12. Open Questions

Pending decisions before post-0.1 planning:
- Keep full-sync only, or add incremental sync in 0.2?
- Add `.bc` support via optional adapter, or stay strictly `.ll`?
- Should references include declaration by default?

