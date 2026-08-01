# Build comparison

SDK and build comparison adds two isolated builds to SDK-derived Analysis. It answers whether the same selected project context produces different structured diagnostics or environment failures under the baseline and candidate Xcodes.

## Before running

Complete project setup and Doctor first. Build comparison uses one exact context:

- project root and selected container;
- shared scheme when required;
- build configuration;
- platform, SDK, and destination;
- architecture and deployment target;
- target membership and active compilation conditions;
- explicit baseline and candidate Xcode roles.

Changing a material field invalidates earlier build evidence. SwiftDelta does not present one build as verification for a different platform or destination.

> **Only analyze projects you trust. Build comparison may execute build phases, package plugins, macros, generators, and other project-provided build tools.**

## Xcode projects and workspaces

For an Xcode container, SwiftDelta invokes `xcodebuild` with the selected scheme, configuration, SDK, and destination under an explicit `DEVELOPER_DIR`. Build-settings inspection receives the same SDK and destination selection.

Baseline and candidate runs use separate temporary roots for:

- DerivedData;
- result bundles;
- module and index caches;
- temporary home and `TMPDIR`;
- SwiftPM scratch, cache, configuration, and security directories;
- relevant tool environment.

The global `xcode-select` setting is never changed. Diagnostic and build evidence retains the Xcode role and identity that produced it.

Doctor validates the Xcode bundle structure, identifier, Apple team identity, signature integrity, required tools, SDK context, and `xcresulttool` capability before a long run. A nonstandard or invalid installation is not silently executed.

## Swift Packages

SwiftDelta compares locally resolvable Swift Packages with each selected toolchain. It creates isolated SwiftPM scratch and state directories and does not modify `Package.swift` or `Package.resolved`.

The comparison can distinguish manifest interpretation failures, tools-version incompatibility, missing local dependencies, macro or plugin loading failures, binary-target platform or architecture mismatch, and unsupported build context when the tools provide that evidence. It does not infer source incompatibility from manifest text alone.

Non-macOS Apple-platform package analysis requires a platform context that the selected local Xcode can build. Unsupported or ambiguous contexts are reported rather than replaced by a host-macOS build.

## Diagnostic readers

SwiftDelta prefers the structured XCResult representation supported by the selected Xcode. It can fall back to legacy XCResult reading, serialized Swift or Clang diagnostics, and normalized `xcodebuild` text when structured data is unavailable.

Equivalent diagnostics from multiple readers are merged by stable identity when available, otherwise by normalized meaning, source location, target, and message. Operation-specific DerivedData and generated-source roots are normalized so baseline and candidate occurrences can match without merging genuinely different targets or files.

The authoritative structured source wins when readers disagree. Severity comparison is directional:

- warning to error is a regression;
- error to warning is an improvement;
- warning to notice is not a regression;
- unchanged diagnostics are not candidate-only findings.

Build exit status alone does not assign diagnostic severity. Environment and tool-operation failures remain Analysis issues.

## Build-failure classification

The default error view gives a short cause and identifies the selected Xcode, container, scheme, SDK, destination, and status. Supported classifications include:

- destination selection;
- missing platform support or SDK;
- signing configuration;
- dependency resolution;
- asset compilation;
- Swift compilation;
- other build phases.

Raw output is bounded and available through technical details rather than streamed into the main interface. A status such as `70` is reported with the underlying destination or platform diagnostic when available.

## Network and execution boundary

SwiftDelta does not intentionally perform network requests and preserves offline package behavior. It does not OS-isolate code launched by the project. A script, plugin, macro, generator, or custom build rule can use the current user's files, credentials, processes, and network access.

Artifact separation prevents baseline and candidate build products from contaminating each other; it is not a security sandbox. Doctor warns about recognizable executable build components, but it cannot prove a project safe. Read [Security](../SECURITY.md).

## Result interpretation

Build diagnostics are combined with SDK and source-resolution evidence in one Analysis result. A source error tied to the candidate compiler is stronger evidence than a declaration-text difference. Conversely, a successful candidate expression can suppress a false exact-identity removal.

An unavailable destination, missing SDK, failed dependency, corrupt result bundle, or build-tool failure does not become a source compatibility finding. When that failure prevents required comparison, the Analysis state is `INCOMPLETE` or `BLOCKED`.

Build success confirms only that the selected build context completed. It does not run the application or prove runtime behavior.
