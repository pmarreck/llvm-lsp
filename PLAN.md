# PLAN

## Current Goal
- Continue toward full LLVM-IR parser coverage via strict TDD, led by failing behavior tests.

## Work Items
- [x] Audit repository and existing `SPEC.md` content for gaps. (completed 2026-02-14 14:19 EST)
- [x] Rewrite `SPEC.md` into an actionable implementation spec for release `0.1.0`. (completed 2026-02-14 14:20 EST)
- [x] Capture plan/progress and repository map updates in `PLAN.md` and `CODE_MINIMAP.md`. (completed 2026-02-14 14:21 EST)
- [x] Add failing CLI tests for M0 lifecycle and debug/release build behavior. (completed 2026-02-14 14:35 EST)
- [x] Scaffold `./build` and `./test` scripts and wire `tests/` layout. (completed 2026-02-14 14:40 EST)
- [x] Implement minimal Zig M0 server (`initialize`, `shutdown`, `exit`, EOF behavior) to satisfy tests. (completed 2026-02-14 14:41 EST)
- [x] Run `./test` and `./build` in both release/debug modes; keep repo in green known-good state. (completed 2026-02-14 14:42 EST)
- [x] Update `CODE_MINIMAP.md` with new scripts and source files. (completed 2026-02-14 14:43 EST)
- [x] Add failing CLI tests for malformed JSON and malformed/partial/oversized framing paths. (completed 2026-02-14 14:49 EST)
- [x] Implement framed JSON-RPC error responses for transport and parse failures (`-32600`, `-32700`). (completed 2026-02-14 14:56 EST)
- [x] Add parser+symbols spike tests for top-level extraction, function scoping, and operand references. (completed 2026-02-14 15:02 EST)
- [x] Implement minimal parser/symbol index and wire unit tests into `zig build test`. (completed 2026-02-14 15:07 EST)
- [x] Re-run full suite and release/debug builds after parser spike. (completed 2026-02-14 15:08 EST)
- [x] Create GitHub repo via `gh`, configure SSH `origin`, and push `yolo` with MIT license commit. (completed 2026-02-14 15:16 EST)
- [x] Add failing parser tests for quoted identifiers with escapes, metadata references, and top-level references. (completed 2026-02-14 15:24 EST)
- [x] Implement minimal parser changes to satisfy new coverage tests while preserving existing behavior. (completed 2026-02-14 15:27 EST)
- [x] Re-run full suite and build matrix after parser coverage increment. (completed 2026-02-14 15:29 EST)
- [x] Update `CODE_MINIMAP.md` for new parser behaviors/tests. (completed 2026-02-14 15:32 EST)
- [ ] Add failing tests for attributes/calling conventions/complex constants and extend parser accordingly.
- [ ] Add failing tests for metadata edge forms (`distinct`, nested tuples, named metadata refs) and extend parser accordingly.
- [ ] Add failing tests for instruction-level reference extraction beyond `%/@/!` token scanning (labels, inline asm edge cases).

## Curiosity Pokes To Revisit
- Clarify whether `references` should include declaration by default.
- Decide whether incremental sync is required for `0.2`.
- Confirm if `.bc` support remains out of scope permanently or is adapter-backed later.
- Validate that LSP framing parser handles partial or malformed headers without hanging.
- Confirm debug banner appears only in debug build and never in release build.
- Ensure parser handles quoted identifiers and metadata forms before wiring into LSP `definition`/`references`.
- Expand parser to collect top-level RHS references (globals/metadata) without treating LHS definitions as references.
