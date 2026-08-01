# Troubleshooting

Start with the state and active phase shown in the TUI. Open technical details only after reading the concise cause; raw tool output is bounded and sanitized.

## SwiftDelta will not launch

Normal launch requires an interactive terminal or PTY. `--help` and `--version` work through pipes, but the full-screen application does not run in a noninteractive stream or in many IDE debug consoles.

If the terminal is too small, resize it to at least 64 columns by 18 rows. Use a larger viewport for side-by-side Analysis and Repair details.

## A former command is rejected

Operational subcommands no longer exist. Run `swiftdelta`, then choose Doctor, Analysis, Repair, cache maintenance, or export inside the TUI. There is no hidden headless mode.

## Project setup cannot complete

Open **Customize Setup ›** and inspect the field marked as requiring attention. SwiftDelta opens a selection sheet automatically when a required value is missing or ambiguous.

Common causes include:

- several unrelated containers under one root;
- no shared scheme for the selected Xcode container;
- a saved Xcode path that no longer exists;
- the same Xcode build selected for both roles;
- no platform context shared by the selected scheme and installed SDKs;
- a destination that does not match the SDK.

Changing one value revalidates its dependents and marks prior Doctor, Analysis, and Repair evidence stale.

## Doctor reports an invalid Xcode

An Xcode selection must be an application bundle with identifier `com.apple.dt.Xcode`, a `Contents/Developer` directory, and an executable `xcodebuild`. Doctor also examines the Apple signing identity and signature integrity. Select another discovered installation or use **Other Xcode…** with a valid application path.

A locally unavailable certificate trust chain is reported separately from a substituted or invalid bundle. Read the technical detail before deciding whether the installation can be trusted.

## The SDK or destination is unavailable

Select only platform contexts discovered from the chosen scheme, targets, build settings, and candidate Xcode. A generic iOS device destination requires the corresponding device platform support. Simulator, device, Catalyst, and macOS contexts are not interchangeable.

If Xcode itself reports a missing platform component, install it outside SwiftDelta using your normal trusted administration process; SwiftDelta does not install Xcode components.

## A comparison build fails

The result distinguishes destination selection, missing platform or SDK, signing, dependency resolution, asset compilation, Swift compilation, and other build phases when the available structured evidence permits it. Environment and build-operation failures remain Analysis issues rather than compatibility findings.

Open the bounded technical detail for the selected Xcode, scheme, SDK, destination, and status. SwiftDelta does not stream unbounded `xcodebuild` output into the main interface.

## Swift Package dependencies are missing

SwiftDelta preserves offline comparison behavior and does not rewrite `Package.swift` or `Package.resolved`. Ensure the dependency is already available in local SwiftPM caches. Doctor reports missing cached dependencies before a long comparison when it can identify them.

Macro, plugin, and binary-target failures are reported as build or context failures, not inferred from manifest text alone.

## Analysis is incomplete

Inspect **Coverage** and **Analysis issues**. Typical causes are:

- a compiler process returned partial output or nonzero status;
- an expected source document was missing, duplicated, malformed, or mapped to the wrong path;
- exact build context could not be captured;
- a generated source, macro, plugin, bridging header, or native translation unit could not be represented;
- symbol-graph extraction and the valid Swift-interface fallback both failed;
- module discovery was incomplete.

SwiftDelta preserves usable partial evidence but does not call it authoritative. Fix the underlying context and rerun; do not interpret an empty list as compatibility.

## Symbol-graph extraction times out

Increase the Analysis timeout under advanced controls. The effective timeout applies to baseline and candidate extraction. Error details identify the operation, SDK, module, Xcode, elapsed time, and effective limit.

When valid, SwiftDelta attempts a Swift-interface fallback and records the extraction source. A module whose extraction methods both fail is marked failed and cannot produce mass-removal findings.

## A warm run does not use the SDK cache

Check the cache policy under Analysis or Settings. `refresh` extracts new evidence and replaces valid entries; `disabled` neither reads nor writes the persistent SDK cache.

Cache identity includes Xcode and SDK paths and versions, the Xcode build, target triple, Swift compiler identity, module, extraction options and mode, access level, snapshot format, and normalization version. A toolchain or format change correctly causes a miss. Corrupt and partial entries are removed rather than used.

## Repair shows no Ready edits

Open the repair funnel and dispositions. A finding can require no source change, lack a replacement API, have unresolved or ambiguous source identity, apply to another platform, or fail syntax or candidate-Xcode verification. Informational SDK changes are not automatically treated as migrations.

Draft Repairs remain visible when a concrete proposal needs anchor correction or review. Edit or validate a Draft again only after understanding the evidence. There is no force-apply path.

## Apple Foundation Models controls are absent

This is expected when the host Mac or operating system is unsupported, Apple Intelligence is disabled by the system, local model assets are not ready, the locale is unsupported, or guided-generation capability is unavailable. SwiftDelta hides unusable model controls and continues deterministic Repair.

The feature uses `SystemLanguageModel.default` only. There is no cloud or network fallback.

## A repair plan is stale

The source changed after the plan was created or validated. Generate a new plan. SwiftDelta refuses to apply a stale fingerprint, mismatched original fragment, or changed range.

## Verification failed

Read the repair's validation result beside its Diff. A proposal stays unselectable when parsing fails, the target evidence remains, a new error appears, severity increases, source-reference coverage regresses, or the build context becomes incomplete.

If failure occurs during Apply, SwiftDelta restores every modified file from retained original bytes and verifies the rollback. The original verification error remains visible even if rollback also reports a problem.

## Restore the terminal after an external force-kill

Normal quit, cancellation, Ctrl-C, SIGTERM, SIGHUP, SIGQUIT, startup errors, and thrown errors restore terminal state. `SIGKILL` cannot be handled. If an external force-kill leaves the terminal altered, run:

```sh
stty sane
printf '\033[?25h\033[?1049l\033[0m'
```

## Report or settings data is rejected

SwiftDelta rejects malformed or newer unsupported settings and repair-plan formats rather than guessing. Safe mode ignores stored settings and history without deleting them:

```sh
swiftdelta --safe-mode
```

Use the checked-in JSON schemas to validate exported native reports and repair plans. Schema versions are independent of the SwiftDelta product version.
