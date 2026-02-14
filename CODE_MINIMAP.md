# CODE_MINIMAP

## Repository Root

`SPEC.md`
- Product and engineering specification for `llvm-lsp`.
- Defines scope, done criteria, functional requirements, architecture, NFRs, test strategy, milestones, and acceptance gates.

`PLAN.md`
- Active work checklist and progress log with EST completion timestamps.
- Includes short curiosity probes for unresolved design decisions.

`build`
- Top-level build script wrapper.
- Invokes `zig build` through `nix develop`, defaults to `ReleaseFast`, supports `--debug` and `--test`.

`test`
- Top-level test runner script with aggregate exit behavior.
- Runs `./build --test` plus executable CLI tests under `tests/cli/`.

`build.zig`
- Zig build graph for `llvm-lsp`.
- Defines executable target and `zig build test` step, with default optimize mode `ReleaseFast`.
- Unit test step now runs `src/tests.zig` so parser/core tests are part of `./test`.

`.github/workflows/ci.yml`
- GitHub Actions CI workflow.
- Runs on `push` to `yolo` and on `pull_request`; installs Nix then executes `./build` and `./test`.

`src/main.zig`
- LSP server runtime and transport implementation.
- Handles framing/lifecycle (`initialize`, `initialized`, `shutdown`, `exit`), plus `didOpen`/`didChange`/`didClose`.
- Implements `definition`, `references`, `documentSymbol`, `hover`, and `completion` request handlers.
- `documentSymbol` emits functions/globals/type aliases/metadata with full-line `range` and token-specific `selectionRange`.
- Implements symbol hover with defining-line context snippets plus opcode-keyword hover fallback (`ret`, `br`, `add`, etc.) when no symbol token is under cursor.
- Implements completion contexts for symbol prefixes (`@`, `%`, `!`), opcode suggestions after `= `, type suggestions after opcode+space, and label suggestions in `br label %` context.
- Publishes diagnostics notifications for parse errors (heuristic malformed tokens), undefined locals, duplicate definitions, missing terminators, and minimal `add i32` type-mismatch warnings after open/change; clears diagnostics on close.
- Emits framed JSON-RPC errors for malformed JSON (`-32700`) and invalid request framing (`-32600`), including oversized content-length rejection.
- Uses a larger bounded session read cap so repeated large full-sync updates can be processed in one stdin session.

`src/tests.zig`
- Unit test entrypoint imported by `zig build test`.
- Pulls in `src/core/parser.zig` and `src/core/symbols.zig` tests.

`src/core/symbols.zig`
- Core symbol/reference index types.
- Defines `SymbolKind`, `Symbol`, `Reference`, and `Index` with query helpers (`countByKind`, `hasDefinition`, `countReferences`).
- `Index` also stores parsed module headers: `source_filename`, `target_triple`, and `target_datalayout`.

`src/core/parser.zig`
- Minimal LLVM IR text parser spike for top-level/module/function-local symbol extraction.
- Captures module headers (`source_filename`, `target triple`, `target datalayout`) into `Index`.
- Parses type aliases, globals, metadata defs, function decl/defs, params, labels, local defs, and operand references with per-function scoping.
- Avoids misclassifying signature type-alias tokens as parameter definitions in calling-convention-heavy signatures.
- Collects top-level RHS references for global/type/metadata assignment lines.
- Collects top-level parameter-signature references from both `declare` and `define` lines.
- Tracks multiline metadata blocks (e.g., `distinct !{ ... }`) to collect continuation-line references.
- Supports quoted `%/@/!` identifiers including escaped quotes within quoted names.
- Supports `#` attribute-group reference capture and branch-label reference capture (`label %foo` => `foo`).
- Contains unit tests validating extraction, `%0` scope isolation across functions, RHS local reference counting, top-level/metadata reference extraction, escaped quoted identifier handling, signature-level type alias references, multiline global constants, and label references.

`tests/cli/m0_lifecycle`
- CLI integration test covering M0 lifecycle behavior.
- Asserts release/debug EOF behavior, initialize response framing/content, shutdown->exit code `0`, and exit-without-shutdown code `1`.

`tests/cli/m0_transport_hardening`
- CLI integration test for malformed/partial/oversized request handling.
- Asserts parse-error and invalid-request error codes, no-hang behavior on partial headers, and non-zero exits for framing failures.

`tests/cli/lsp_navigation`
- Integration test for document open + navigation flow.
- Verifies `definition`, `references`, and `documentSymbol` responses in a single LSP session.

`tests/cli/lsp_assist`
- Integration test for assistive features.
- Verifies `hover` plus completion contexts for `@`, `%`, `!`, opcode suggestions (`= `), and type suggestions (opcode + space).

`tests/cli/lsp_diagnostics`
- Integration test for diagnostics notifications.
- Verifies parse-error, undefined-symbol, duplicate-definition, missing-terminator, and type-mismatch diagnostics with expected severities.

`tests/cli/lsp_document_lifecycle`
- Integration test for document synchronization semantics.
- Verifies `didChange` reparses content and `didClose` invalidates lookup results.

`tests/cli/lsp_hover_label_completion`
- Integration test for opcode hover and branch-label completion.
- Verifies hover description for `ret` and completion labels in `br label %` context.

`tests/cli/lsp_errors`
- Integration test for JSON-RPC error handling paths.
- Verifies `-32601` for unknown methods and `-32600` for malformed requests missing `method`.

`tests/cli/lsp_document_symbol_fidelity`
- Integration test for richer `documentSymbol` behavior.
- Verifies metadata symbol inclusion and line/token range fidelity for emitted symbols.

`tests/cli/ci_workflow`
- CI guard test.
- Verifies workflow presence and that it triggers on `push`/`pull_request` while running `./build` and `./test`.

`tests/cli/lsp_large_file_stress`
- Large-file integration test.
- Verifies multi-megabyte `didOpen` + `didChange` full-sync flow and post-change `definition` resolution.

`flake.nix`
- Nix flake defining project development shell and default package build.
- Exposes Zig/ZLS toolchain and `zig build -Doptimize=ReleaseFast` package build behavior.

`flake.lock`
- Nix input lockfile for reproducible dependency resolution.

`AGENTS.md` (symlink)
- Workspace collaboration and engineering process rules.

`ZIG_RECENT_API_CHANGES_2025.md` (symlink)
- Zig API migration notes relevant to 0.14/0.15 behavior changes.

`jj_cheatsheet.md` (symlink)
- Quick-reference guide for `jj` workflow commands.
