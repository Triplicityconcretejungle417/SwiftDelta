# SwiftDelta documentation

Start with the tutorial for a first comparison. Use the task guides while operating SwiftDelta and the explanation or reference pages when you need the underlying contract.

## Start here

- [Getting started](GettingStarted.md) takes a local project from selection through Doctor, Analysis, report export, and Repair preview.

## Task guides

| Task | Guide |
| --- | --- |
| Select a project and operate the TUI | [Terminal interface](TerminalInterface.md) |
| Compare real builds under two Xcodes | [Build comparison](BuildComparison.md) |
| Review, validate, and apply source changes | [Repair](Repair.md) |
| Export terminal, JSON, SARIF, or repair plans | [Reports](Reports.md) |
| Resolve setup, coverage, build, or terminal failures | [Troubleshooting](Troubleshooting.md) |
| Build and verify a contribution | [Testing](Testing.md) |

## Explanation

- [Analysis](Analysis.md) explains SDK extraction, target-aware reference resolution, comparison, confidence, and completeness.
- [Architecture](Architecture.md) follows data from project discovery to findings, repair validation, and reports.
- [Security](../SECURITY.md) defines the trust boundary around project-provided build logic.

## Reference

- [Configuration](Configuration.md) lists project configuration fields, persistent settings, defaults, and cache controls.
- [Reports](Reports.md) records result states, schema versions, and export contracts.
- [Terminal interface](TerminalInterface.md#keyboard-and-mouse-reference) lists every discoverable control and accelerator.
- [FAQ](FAQ.md) answers concise behavior and scope questions.

## Project documents

- [README](../README.md)
- [Contributing](../CONTRIBUTING.md)
- [Security policy](../SECURITY.md)
- [Code of Conduct](../CODE_OF_CONDUCT.md)
- [Changelog](../CHANGELOG.md)
- [License](../LICENSE)

The checked-in schemas are [SwiftDeltaReport.schema.json](Schemas/SwiftDeltaReport.schema.json) and [RepairPlan.schema.json](Schemas/RepairPlan.schema.json).
