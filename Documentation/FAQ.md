# Frequently asked questions

## Does SwiftDelta contain a database of Apple API migrations?

No. It derives compatibility evidence from the two selected Xcode SDKs, compiler diagnostics, structured Fix-its, symbol metadata, Swift interfaces, Clang evidence, and resolved project source.

## Does SwiftDelta replace normal testing?

No. It can establish that a selected candidate build context accepts a verified edit, but it cannot prove runtime behavior, UI behavior, permissions, lifecycle behavior, data migration, race freedom, or business logic.

## Does it launch the application?

No. Analysis may parse, type-check, index, or build source, but SwiftDelta does not launch the target product.

## Why are two Xcodes required?

The baseline records the current SDK and compiler behavior; the candidate records the proposed upgrade. SwiftDelta requires an explicit role for each and refuses the same installation or equivalent build in both roles.

## Can it analyze more than one Apple platform?

The TUI presents contexts supported by the selected scheme and targets. Each Analysis run is bound to its selected SDK, destination, architecture, deployment target, and platform variant. Do not treat device, simulator, Catalyst, and macOS evidence as interchangeable.

## Does SwiftDelta support Swift Packages?

Yes, when the package and dependencies are locally resolvable with the selected toolchains. Package comparison reports manifest, dependency, plugin, macro, binary-target, and build-context failures from structured tool evidence. It does not edit `Package.swift` or `Package.resolved`.

## What does incomplete mean?

Required target, source, or SDK evidence did not finish. SwiftDelta may still show partial evidence, but it does not call the result a pass. Coverage identifies the affected files, modules, toolchain, and reason.

## Can SwiftDelta repair every finding?

No. Automatic repair requires exact source and replacement evidence plus successful candidate-Xcode verification. Many availability, concurrency, ownership, architecture, and behavior changes require human judgment. Every finding receives a disposition explaining why it is Ready, needs review, or has no safe fix.

## What is a Draft Repair?

A Draft is a concrete proposal that has not met the Ready requirements. Its anchors may need correction, its risks may require review, or isolated verification may have failed. Drafts can be inspected, edited, and validated again, but not force-applied.

## Does Apply reformat whole files?

No. It applies exact ranges, preserves UTF-8, line endings, final-newline state, permissions, comments, and untouched whitespace. The transaction rejects stale, overlapping, contradictory, escaping, protected, generated, dependency, metadata, binary, and unsupported edits.

## What happens when verification fails?

Preview and isolated validation leave the original project unchanged. During Apply, any failed write or final verification restores every selected file from retained original bytes and checks that restoration succeeded.

## Does Apple Foundation Models send source to the cloud?

No. SwiftDelta uses the host Mac's `SystemLanguageModel.default` only. There is no Private Cloud Compute or remote fallback. The model receives bounded context for one finding, and SwiftDelta retains authority over files, ranges, SDK identity, validation, and Apply.

## Why are the model controls missing?

SwiftDelta hides them when the on-device model is unsupported, disabled by the system, not ready, unsuitable for the current locale, or missing a required capability. Deterministic Analysis and Repair continue normally.

## Does SwiftDelta access the network?

SwiftDelta does not intentionally make network requests during analysis. Project-provided build scripts, plugins, macros, generators, and custom rules run outside an OS sandbox and may use the network. Building SwiftDelta from source may also cause SwiftPM to resolve its declared dependency unless it is already cached.

## How should I report a security vulnerability?

Follow the private reporting instructions in the [security policy](../SECURITY.md). Do not place vulnerability details in a public issue. The published security address is not a general support channel.

## Where is local state stored?

Settings are under `~/Library/Application Support/SwiftDelta`; recent-project history is optional and disabled by default. SDK snapshots are under `~/Library/Caches/org.swiftdelta/SDKSnapshots/v1`. No state is written into an analyzed project unless the user explicitly confirms Apply for selected source files.

## Is there a headless or CI mode?

No. `swiftdelta` is a full-screen TUI. Help and version are the only noninteractive outputs. Reports can be exported from the Analysis screen for later use by other tools.

## Can I use Objective-C, C, or C++ projects?

Swift-facing imported declarations participate through Clang Importer evidence. Native Objective-C, Objective-C++, C, and C++ diagnostics can use target-aware Clang evidence where available, but native automatic repair remains limited to exact compiler-provided Clang Fix-its. SwiftDelta does not claim complete native migration coverage.

## Which report format should I choose?

Use terminal text for reading, native JSON for the complete SwiftDelta data model, and SARIF for tools that understand SARIF locations and notifications. A repair plan is a separate versioned format and is not an Analysis report.
