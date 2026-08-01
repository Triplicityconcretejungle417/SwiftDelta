# Testing and local development

SwiftDelta's normal test suite is deterministic and uses fictional fixtures. Real-toolchain and on-device model tests are opt-in because their prerequisites depend on the host Mac.

Never use a personal, business, or unrelated project as an analyzed test target. Create fixtures in unique temporary directories and remove every artifact on success and failure.

## Build and test

From the package root:

```sh
swift build
swift test
swift build -c release
```

SwiftPM may resolve SwiftSyntax `603.0.2` if it is not already cached. For an offline run with local dependency state, add `--disable-automatic-resolution`. Use `--scratch-path` with a unique directory outside the source tree when auditing cleanup or release output.

Help and version can be tested through pipes:

```sh
swift run swiftdelta --help
swift run swiftdelta --version
```

The full TUI needs a real pseudo-terminal. A pipe is suitable only for the expected non-TTY failure path.

## Test organization

`Tests/SwiftDeltaCoreTests` follows the core subsystems:

- discovery and configuration;
- build settings, Xcode identity, isolated builders, and failure classification;
- SDK extraction, fallback, normalization, cache, timeout, and comparison;
- target-aware source coverage and overload compatibility;
- structured and fallback diagnostic readers;
- terminal, JSON, SARIF, and schema contracts;
- deterministic repair, model Drafts, conflicts, transactions, validation, verification, rollback, and cleanup;
- synthetic integration fixtures.

`Tests/SwiftDeltaCLITests` covers:

- launch-only argument parsing and former-command rejection;
- TUI setup, navigation, focus, selection, mouse input, sheets, and missing-value resumption;
- findings, repair lists, Diffs, Draft editing, and Apply confirmation;
- terminal capabilities, native backgrounds, Unicode width, clipping, and external-text sanitization;
- settings, history, safe mode, corruption recovery, and atomic writes;
- progress, resize, cancellation, signals, PTY lifecycle, and terminal restoration.

Keep expensive engines behind deterministic service implementations in ordinary TUI tests. Core integration tests should exercise the real service boundary with synthetic projects.

## Fixture rules

- Use fictional module, target, symbol, and API names.
- Derive SDK test behavior from synthetic symbol graphs or interfaces rather than encoding a real Apple migration rule.
- Use unique temporary roots for projects, DerivedData, result bundles, module caches, indexes, reports, settings, repair staging, and SwiftPM state.
- Preserve byte-level fixtures for line endings, final newlines, permissions, Unicode, and stale-plan tests.
- Keep parser and property-style runs deterministic and bounded.
- Do not weaken an assertion, hide an error, or convert a required failure to a skip.

## Two-Xcode integration

Real integration receives machine-specific paths only through environment variables:

```sh
SWIFTDELTA_BASELINE_XCODE="/path/to/baseline/Xcode.app" \
SWIFTDELTA_CANDIDATE_XCODE="/path/to/candidate/Xcode.app" \
SWIFTDELTA_BASELINE_VERSION="expected-version" \
SWIFTDELTA_BASELINE_BUILD="expected-build" \
SWIFTDELTA_BASELINE_SDK="expected-sdk" \
SWIFTDELTA_CANDIDATE_VERSION="expected-version" \
SWIFTDELTA_CANDIDATE_BUILD="expected-build" \
SWIFTDELTA_CANDIDATE_SDK="expected-sdk" \
swift test
```

The harness creates synthetic packages and Xcode containers. It verifies Xcode identity, independent `DEVELOPER_DIR`, isolated artifacts, SDK extraction, target-aware references, project and package comparison, XCResult reading, compiler severity, Swift Fix-its, Clang Fix-its where supported, repair Apply, candidate verification, and forced rollback.

Do not store local Xcode paths in production defaults or committed fixtures. Never change global `xcode-select`.

## Apple Foundation Models integration

Normal tests inject deterministic providers. The real provider runs only when explicitly enabled:

```sh
SWIFTDELTA_RUN_ON_DEVICE_MODEL_TEST=1 swift test
```

The opt-in tests first check `SystemLanguageModel.default` availability. They use fictional bounded source context and the typed structured-generation path. When the host supports it, integration covers Draft creation, anchor normalization, isolated validation, promotion, transactional Apply, and candidate-Xcode verification.

If the system model is unsupported, disabled, not ready, unsupported for the locale, or missing capability, the test reports the exact unavailable prerequisite. It must not be counted as passed. No cloud-model test path exists.

## TUI and PTY verification

Rendering tests cover 80×24, 100×28, 128×32, and 160×50 layouts plus the minimum-size state. Capability fixtures cover light and dark assumptions, True Color, 256-color, basic color, monochrome, `NO_COLOR`, high contrast, Unicode, ASCII, and reduced motion.

PTY tests verify launch, input split across reads, mouse sequences, resize, cancellation, normal quit, Ctrl-C, SIGTERM, SIGHUP, and terminal restoration. Avoid timing assertions on animation frames; inject a deterministic clock where phase matters.

## Report validation

Tests must encode and validate native JSON and repair plans against the checked-in schemas, verify SARIF `2.1.0` structure, confirm project-relative paths, and preserve deterministic ordering and identifiers. Product, report, repair-plan, SDK snapshot, cache, and settings versions are independent contracts.

## Before submitting a change

Run the tests relevant to the changed subsystem, then the complete suite and both debug and release builds. For process, terminal, cache, or repair changes, repeat the deterministic suite to detect flakes and run the applicable real synthetic integration when prerequisites exist.

Finally, inspect the package root and scratch locations for `.build`, DerivedData, result bundles, module and index caches, SDK snapshots, reports, PTY captures, model output, repair staging, logs, and synthetic projects. Remove only artifacts produced during the test run.
