# Contributing to SwiftDelta

SwiftDelta compares local Apple toolchains and can propose verified source edits. Changes therefore need evidence, deterministic tests, and careful treatment of project-provided code.

Read the [architecture](Documentation/Architecture.md), [security policy](SECURITY.md), and the focused document for the subsystem you plan to change before editing.

## Development requirements

- macOS 13 or later
- Swift 6.4
- SwiftSyntax `603.0.2`
- local Xcode installations for opt-in toolchain integration
- an actual terminal or PTY for interactive tests

The package has an executable target, a reusable `SwiftDeltaCore` library, a native diagnostic bridge, core tests, and TUI tests. See [Testing](Documentation/Testing.md) for commands and integration environment variables.

## Architecture orientation

`Sources/SwiftDeltaCore` owns discovery, configuration, builds, SDK extraction, source resolution, diagnostics, reports, and Repair. `Sources/SwiftDelta` owns launch parsing and terminal presentation. Keep analysis policy out of the renderer, and keep terminal state out of the core.

Use existing process, filesystem, clock, build, model, and verification boundaries for testability. Add an abstraction when a real external boundary requires one, not to hide a local function.

## Compatibility expectations

Unless a change deliberately versions a contract, preserve:

- the launch-only argument set and TUI workflow;
- public Swift APIs;
- project configuration fields and defaults;
- settings and cache formats;
- native JSON, SARIF, and repair-plan schemas;
- finding identifiers, ordering, severity, and confidence meaning;
- strict completeness and exit-status evaluation;
- repair path protection, fingerprints, transactions, verification, and rollback.

A product-version change does not imply a report or settings format change.

## SDK and Analysis changes

Apple API facts must come from the selected Xcode SDKs and compilers. A compatibility change should improve a structured reader, identity resolver, normalizer, semantic comparator, or evidence correlation step.

Do not add:

- a built-in Apple API migration list;
- an API-specific production exception;
- a high-confidence result from an unqualified textual match;
- migration advice that is not supplied by the SDK or compiler;
- mass-removal findings after partial extraction;
- source findings for environment or build-operation failures.

Preserve the baseline and candidate toolchain, SDK, module, target, source, and extraction-quality evidence. When required context is missing, report incomplete coverage.

Compiler severity and SwiftDelta confidence are independent. Tests for diagnostic changes should include improvements and regressions, not only newly introduced errors.

## Repair changes

Use the evidence priority in [Repair](Documentation/Repair.md). A new automatic path needs exact source identity, a bounded edit, candidate symbol evidence, conflict handling, isolated validation, and final transactional verification.

Do not convert review advice into an automatic repair. Do not bypass protected paths, SHA-256 fingerprints, stale-plan rejection, parsing, source coverage, diagnostic regression checks, or rollback to increase coverage.

Model-related changes must retain on-device-only `SystemLanguageModel.default`, typed structured output, bounded requests, no tools, no cloud fallback, explicit provenance, and program-owned paths and ranges. Normal tests must use deterministic providers; a real model test remains opt-in.

## Security-sensitive changes

Process execution, Xcode discovery, build isolation, terminal escape handling, settings, caches, reports, and source writes are security-sensitive.

> **Only analyze projects you trust. Build comparison and repair verification may execute build phases, package plugins, macros, generators, and other project-provided build tools.**

Do not describe Doctor or artifact isolation as a sandbox. Project-provided executables may access the user's files and network. Preserve explicit argument execution, bounded output, redaction, cancellation, temporary isolation, and cleanup.

Security changes need malformed-input, path traversal, symlink, interrupted-write, and rollback tests appropriate to the boundary.

## Tests for a change

Add the smallest deterministic fixture that proves the behavior and its failure boundary. Use fictional projects, SDK declarations, symbols, and diagnostics in unique temporary directories.

Depending on the change, test:

- normal, empty, malformed, partial, stale, and cancellation paths;
- Unicode and UTF-8 boundaries;
- deterministic ordering and stable identifiers;
- baseline and candidate isolation;
- incomplete coverage rather than silent success;
- preview leaving source unchanged;
- failed verification restoring every byte;
- terminal capability and narrow-layout fallbacks;
- schema compatibility.

Do not use a real user project as a fixture. Do not weaken an assertion, hide an error, or mark a required path skipped to make a run pass. List unavailable opt-in prerequisites accurately.

## Code and comment style

Match the surrounding Swift style and file organization. Prefer concrete types and short functions at policy boundaries. Keep errors actionable without exposing internal type names.

Comments should explain why a constraint, fallback, or safety decision exists. Do not narrate self-explanatory control flow. Preserve the project source banner and existing license notices.

## Documentation changes

Update the README only for front-page behavior. Put detailed workflows and contracts in `Documentation`. Commands must be executable as written, links must be relative and valid, and claims must match current code.

Do not include machine paths, private project names, transient test counts, or unverified performance figures. Update a schema reference when its contract changes.

## Pull request quality

A reviewable change should:

- state the observed defect or capability boundary;
- explain the evidence and design tradeoff;
- keep unrelated formatting out of the change;
- include tests that fail before the fix and pass after it;
- identify public contract or schema effects;
- record debug, release, deterministic, and applicable integration results;
- list skipped checks with an exact reason;
- leave no build, result-bundle, cache, report, log, or synthetic-project artifact.

Security vulnerabilities should be sent through the private route in [SECURITY.md](SECURITY.md), not opened as public issues. Conduct expectations are in [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
