# Getting started

This tutorial completes one comparison without changing source. It assumes the project can be built locally and that two Xcode installations are already present.

> **Only analyze projects you trust. Build comparison and repair verification may execute build phases, package plugins, macros, generators, and other project-provided build tools.**

## Before you launch

You need:

- macOS 13 or later;
- the SwiftDelta executable built with Swift 6.4;
- an interactive terminal or PTY;
- a project root containing a Swift Package, Xcode project, or Xcode workspace;
- two distinct local Xcode installations;
- locally available project dependencies.

Close any process that is actively rewriting the project while SwiftDelta runs. Repair plans use source fingerprints and become stale when a file changes.

## 1. Open the project

Launch SwiftDelta:

```sh
swiftdelta
```

Select **Project**, then choose or enter the root directory. You can also preselect it at launch:

```sh
swiftdelta --project /path/to/project-root
```

Preselection starts asynchronous setup discovery inside the TUI. It can continue to automatic Doctor validation once the required choices are complete, but it never starts Analysis or Repair.

SwiftDelta discovers candidate containers, shared schemes, build configurations, and supported platform contexts in the background. If one container or scheme is clearly associated with the selected root, it can be selected automatically. Ambiguous choices appear in a focused sheet; values already resolved remain intact.

## 2. Confirm the build context

Choose the **Baseline Xcode** and **Candidate Xcode** from the discovered applications. Each row shows its version, build, path, and relevant installed SDKs. SwiftDelta does not assign these roles automatically and rejects the same installation or equivalent build in both roles.

Choose a platform context supported by the selected scheme and targets. User-facing choices such as **iOS Device**, **iOS Simulator**, **Mac Catalyst**, and **macOS** carry the matching SDK and destination. SwiftDelta does not infer a material platform choice on your behalf.

Open **Customize Setup ›** only when you need to inspect or replace the container, scheme, configuration, Xcodes, platform, SDK, destination, compilation conditions, or exclusions. Each field records whether its value was discovered, loaded from project configuration, or selected manually.

## 3. Let Doctor validate the setup

Doctor becomes available only when the required setup fields are complete. It starts automatically after setup is ready and remains available through **Run Doctor Again**.

Doctor checks the project container, local dependency availability, selected Xcode bundle identity and signing integrity, command-line tools, SDK and destination, target build context, cache and temporary-directory writability, and known build-execution risks. It does not generate compatibility findings.

Resolve blocking issues before continuing. Warnings about scripts, plugins, macros, generators, or custom build rules mean that later build comparison or repair verification can execute project-provided code. Doctor is not a sandbox.

Select **Continue to Analysis** after Doctor succeeds. This navigates only; it does not start work.

## 4. Run Analysis

Choose one mode:

- **SDK analysis** extracts and compares SDK evidence and resolves project source references.
- **SDK and build comparison** also builds the selected context with both Xcodes and compares structured diagnostics.

Review the context summary, then select **Run Analysis**. Advanced controls include finding thresholds, uncertain findings, timeout, strict completeness, progress verbosity, SDK cache policy, report format, and report path.

During execution, the progress panel shows the active phase and elapsed time. Escape requests cancellation and returns the application to a stable state after child processes and temporary files have been cleaned up.

## 5. Read the result

Start with the state:

- `PASS`: required analysis completed below the configured failure threshold;
- `FAIL`: required analysis completed with a finding at or above the threshold;
- `INCOMPLETE`: required coverage did not finish;
- `BLOCKED`: an operational or toolchain failure prevented analysis.

Then inspect **Coverage**. Baseline and candidate entries state which files were requested, analyzed, excluded, generated, failed, or contained no SDK references. They also report stable and unresolved references and the selected SDK modules. Treat `INCOMPLETE` and `BLOCKED` as a request to fix the analysis context, not as evidence of compatibility.

Use search, severity filtering, grouping, and sorting in **Findings**. Select a row to inspect the source location, baseline and candidate declarations, compiler evidence, confidence, and repair availability. Operational failures stay under **Analysis issues** rather than becoming source findings.

## 6. Export a report

Choose terminal, JSON, or SARIF on the Analysis screen, set an output path, and select **Export**. When the path is missing, SwiftDelta opens a validated path sheet and resumes the export after confirmation.

Export does not rerun Analysis. JSON uses report format `3.0`; SARIF uses `2.1.0`. See [Reports](Reports.md).

## 7. Preview Repair

Select **Continue to Repair**. With current Analysis evidence, SwiftDelta begins bounded repair planning and isolated validation automatically. It does not select or apply an edit.

The repair funnel shows how many findings were actionable, proposed, validated, Ready, and selected. Every Analysis finding receives a disposition, including a precise reason when no source change is required or no safe proposal can be established.

Open a repair to inspect its Diff, evidence, assumptions, risks, and validation state. Ready repairs can be selected with Space or the visible selection action. Draft and review-only proposals remain inspectable and can be edited or validated again, but cannot be force-applied.

Stop here for a read-only evaluation. No source has changed.

## 8. Apply only after review

If you choose to continue, select Ready repairs and confirm **Apply Selected Repairs**. SwiftDelta rechecks fingerprints, ranges, original text, paths, conflicts, and plan freshness; writes through a transaction; rebuilds and reanalyzes with the candidate Xcode; and restores all modified bytes if final verification fails.

Run the project's own tests after a successful Apply. SwiftDelta reports build verification, not runtime or business-logic correctness.

## Next steps

- [Understand Analysis evidence and completeness](Analysis.md)
- [Review the Repair safety model](Repair.md)
- [Configure defaults and local state](Configuration.md)
- [Troubleshoot incomplete or blocked work](Troubleshooting.md)
