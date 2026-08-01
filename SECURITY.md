# Security policy

## Supported versions

| Version | Security support |
| --- | --- |
| 1.0.x | Current |
| Earlier releases | Not supported |

The source tree does not publish a response-time guarantee.

## Trust the project before analyzing it

> **Only analyze projects you trust. Build comparison and repair verification may execute build phases, package plugins, macros, generators, and other project-provided build tools.**

SwiftDelta does not launch the target application. It does invoke Xcode, Swift, Clang, SwiftPM, `xcresulttool`, symbol extraction, and related developer tools. A target project's scripts, plugins, macros, generators, custom rules, and other build tools run with the permissions of the SwiftDelta process.

Doctor reports known executable build components and environment problems that it can identify. It is not an operating-system sandbox and cannot prove a project safe.

SwiftDelta does not intentionally make network requests during analysis. It does not OS-isolate project-provided build logic from network access. Such code can use the user's files, credentials, processes, and network according to the host operating system's permissions.

## Report a vulnerability

Send security vulnerabilities privately to [lijiaxudeapple@icloud.com](mailto:lijiaxudeapple@icloud.com). Do not initially report a vulnerability through a public issue. This address is for security reports, not general product support.

Use a subject such as:

```text
[SwiftDelta Security] Brief description
```

Include:

- affected SwiftDelta version;
- macOS and Xcode versions;
- reproduction steps;
- the security impact;
- relevant logs with secrets and personal paths removed;
- whether the issue has already been disclosed elsewhere.

Do not attach credentials, signing material, private source, exploit data unrelated to the report, or a real project archive. No response or remediation timeline is promised.

## Process execution and isolation

SwiftDelta validates selected Xcode bundles before tool execution. Doctor checks the Xcode bundle identifier, Apple team identity, designated requirement, signature integrity, command-line tools, SDK context, and `xcresulttool` behavior. A trust-chain evaluation problem is reported separately from an invalid identity or signature.

Baseline and candidate builds use separate `DEVELOPER_DIR`, DerivedData, result bundles, module and index caches, SwiftPM state, temporary home, and `TMPDIR`. SwiftDelta never changes global `xcode-select`.

These controls prevent toolchain artifact mixing. They do not sandbox project-provided code.

Subprocesses receive explicit executable paths and arguments rather than shell-interpolated command strings. Output is bounded and sanitized before display, and common secret-shaped environment assignments are redacted from surfaced errors. Cancellation and supported termination signals stop child work and clean temporary artifacts.

## Source and report privacy

SwiftDelta reads source needed for Analysis and Repair. It does not intentionally persist source code, complete compiler logs, model source context, temporary project copies, repair staging data, or secrets in application settings.

Reports and repair plans are written only when explicitly exported. They may contain source paths, declarations, diagnostics, and compatibility evidence. Review them before sharing.

Optional recent-project history is disabled by default. SDK cache entries contain normalized SDK metadata rather than project source and are protected by identity checks and a SHA-256 payload digest.

Apple Foundation Models repair uses only the host Mac's local `SystemLanguageModel.default`. SwiftDelta supplies no tools to the model and has no Private Cloud Compute, cloud, remote, or network fallback for source repair.

## Repair safety boundary

Repair preview and Draft editing do not modify the original project. Viable proposals are first applied to isolated copies for parsing, source resolution, and candidate-Xcode build validation.

Apply requires explicit confirmation and may modify only selected supported source files inside the canonical project root. Before writing, SwiftDelta validates:

- canonical containment and symlink resolution;
- protected and generated path policy;
- UTF-8 source and exact original text;
- SHA-256 file fingerprint;
- normalized ranges and anchors;
- duplicate, overlapping, contradictory, and stale edits;
- candidate SDK and compiler evidence.

The transaction retains original file bytes and permissions. Final verification repeats the selected candidate build and target-aware Analysis. If a write or verification step fails, SwiftDelta restores every modified file byte-for-byte and verifies the rollback. There is no unverified Apply option.

Build success does not prove runtime behavior, business logic, data migration, permissions, lifecycle behavior, concurrency correctness, memory lifetime, or semantic equivalence. Review the Diff and run the project's own tests.

## Data to exclude from reports

Before sharing an exported report, remove any private project names, paths, source fragments, diagnostics, URLs, account names, or environment details that the recipient does not need. Use a fictional reproducer whenever possible.
