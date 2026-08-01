# Changelog

This file records user-visible SwiftDelta changes. Format and schema versions are listed separately when they change.

## Unreleased

- Refined the documentation workflow, interface captures, cross-document navigation, and private security-reporting instructions.

## 1.0.0 — 2026-08-01

Initial 1.0 release.

### Terminal application

- Added the full-screen Home, setup, Doctor, Analysis, Repair, Settings, Help, and About workflow.
- Limited noninteractive launch behavior to help, version, safe mode, and project preselection; operational subcommands are not supported.
- Added keyboard and optional mouse operation, responsive layouts, terminal capability fallbacks, reduced motion, sanitized external text, cancellation, signal handling, and terminal restoration.
- Added versioned atomic settings, optional recent-project history, and SwiftDelta-owned SDK cache maintenance.

### Analysis

- Added target-aware project, workspace, and locally resolvable Swift Package discovery and build context.
- Added SDK-derived symbol extraction, Swift-interface fallback, source-reference resolution, normalized SDK comparison, and persistent integrity-checked module caching.
- Added separate baseline and candidate source coverage, per-file dispositions, module extraction quality, strict completeness, and `PASS`, `FAIL`, `INCOMPLETE`, and `BLOCKED` states.
- Added isolated two-Xcode build comparison, modern and legacy XCResult readers, serialized diagnostics, normalized text fallback, directional severity comparison, and actionable build-failure classification.
- Added terminal, native JSON format `3.0`, and SARIF `2.1.0` export with project-relative locations.

### Repair

- Added preview-first deterministic repair from structured Swift and Clang Fix-its, exact SDK rename metadata, and mechanically compatible signature evidence.
- Added per-finding repair dispositions, Draft Repairs, Diff inspection, editing, isolated automatic validation, Ready selection, and versioned repair-plan format `3.0`.
- Added optional on-device Apple Foundation Models planning through typed structured generation with no cloud fallback.
- Added protected-path checks, SHA-256 fingerprints, stale-plan and conflict rejection, transactional Apply, candidate-Xcode reanalysis, and complete rollback.

### Development

- Adopted Swift 6.4, macOS 13 as the package minimum, and stable SwiftSyntax `603.0.2`.
- Added deterministic core, TUI, schema, PTY, transaction, rollback, cache, and opt-in synthetic toolchain integration coverage.
