# Reports and result states

The Analysis screen is the primary result view. Export serializes the current result without rerunning Analysis or changing its findings.

## Analysis states

`AnalysisReport.analysisState` has four values:

| Native value | TUI label | Meaning |
| --- | --- | --- |
| `completeAndClean` | `PASS` | Required analysis completed and no qualifying finding exists. |
| `completeWithFindings` | `PASS` or `FAIL` | Required analysis completed; the failure threshold determines the label. |
| `incomplete` | `INCOMPLETE` | Some evidence exists, but required target, source, or SDK coverage did not complete. |
| `blocked` | `BLOCKED` | An operational or toolchain failure prevented required analysis. |

An empty finding list is not a pass when coverage is incomplete. `allowIncomplete` changes threshold evaluation behavior for consumers that opt in; it does not make missing evidence complete.

The core exit-status evaluator remains:

- `0`: complete analysis with no finding at the configured failure threshold;
- `1`: complete analysis with a finding at the threshold;
- `2`: required analysis is incomplete or blocked.

The full-screen application does not exit after each operation. It displays and exports the same classification.

## Terminal report

Terminal output includes:

- result state and context;
- ordered findings with severity and confidence;
- project-relative source locations;
- SDK and compiler migration messages when supplied by those tools;
- analysis issues;
- baseline and candidate reference coverage;
- failed or missing source-file dispositions;
- selected SDK modules and their reasons;
- a severity and issue summary.

Terminal export is plain, line-oriented text rather than a TUI capture.

## Native JSON

Native JSON uses `reportFormatVersion` `3.0`. The contract is checked in at [SwiftDeltaReport.schema.json](Schemas/SwiftDeltaReport.schema.json).

The report contains:

- product and format metadata;
- project root and generation time;
- Analysis state;
- findings and exact SDK evidence;
- operational failures;
- baseline and candidate reference coverage by SDK and target;
- source-file dispositions and unresolved-reason counts;
- selected SDK modules and discovery reasons.

The renderer uses sorted keys and normalizes fields named `path` to project-relative paths when they are below the selected root. Paths outside that root remain absolute because rewriting them as project content would be misleading.

## SARIF

SARIF output uses version `2.1.0`. It declares `PROJECT_ROOT` as the URI base and records project-relative artifact locations for findings. Severity maps to SARIF `error`, `warning`, or `note` without changing the compiler's meaning.

Each result includes category, confidence, origin, automatic-remediation availability, SDK evidence, and migration text when present. Run properties contain Analysis state, reference coverage, and SDK module selection. Incomplete and operational failures appear as tool-execution notifications rather than source findings.

SARIF is exported explicitly from the TUI. SwiftDelta has no headless CI runner.

## Finding evidence

SDK findings retain:

- baseline and candidate Xcode version and build;
- baseline and candidate SDK version;
- module, platform, qualified symbol, and stable identity when available;
- target and configuration context;
- source location;
- change kind and observed change;
- old and new declarations and availability;
- reference-resolution method;
- confidence;
- SDK- or compiler-supplied migration text.

Compiler diagnostic severity and SwiftDelta confidence are separate fields. Equivalent diagnostics from multiple readers are merged without inventing a stronger severity.

## Stability and ordering

Findings use stable identifiers derived from stable evidence, source context, and meaning. Ordering is deterministic. Per-run generation time remains separate from finding identity.

Report schema versions are independent of the SwiftDelta product version, SDK snapshot format, settings format, and repair-plan format. A product release does not silently change a schema.

## Repair plans

Repair plans are not Analysis reports. JSON repair plans use `repairPlanFormatVersion` `3.0` and [RepairPlan.schema.json](Schemas/RepairPlan.schema.json). A plan contains proposed edits, fingerprints, evidence, safety and confidence classifications, conflicts, planning failures, toolchain and symbol identities, and Apple Foundation Models provenance when applicable.

Diff preview and JSON plan export remain preview artifacts. Loading a plan does not bypass stale-file, path, conflict, or verification checks. See [Repair](Repair.md).
