# Configuration and local state

SwiftDelta keeps project analysis defaults separate from application settings. Project configuration can travel with a project if its owners choose to provide it. TUI settings and optional history stay under the user's Application Support directory.

Neither form starts an operation automatically or replaces an explicit setup choice without validation.

## Project configuration

SwiftDelta reads `.swiftdelta.json` from the selected project root by default. **Customize Setup ›** can select another existing JSON file. The application does not create or rewrite project configuration.

All fields are optional:

```json
{
  "defaultWorkspace": "Example.xcworkspace",
  "defaultScheme": "Example",
  "baselineXcodePath": "/Applications/Xcode-Baseline.app",
  "candidateXcodePath": "/Applications/Xcode-Candidate.app",
  "sdkIdentifiers": ["iphoneos"],
  "activeCompilationConditions": ["FEATURE_FLAG"],
  "excludedPaths": ["Fixtures"],
  "minimumSeverity": "notice",
  "minimumConfidence": "medium",
  "ciFailureLevel": "error",
  "outputFormat": "terminal"
}
```

Do not include both `defaultWorkspace` and `defaultProject`. Paths may be relative to the selected root. Xcode roles and the platform still require explicit confirmation in the TUI; stored paths are validated before use.

### Field reference

| Field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `defaultWorkspace` | string | unset | Preferred `.xcworkspace` path. Mutually exclusive with `defaultProject`. |
| `defaultProject` | string | unset | Preferred `.xcodeproj` path. Mutually exclusive with `defaultWorkspace`. |
| `defaultScheme` | string | unset | Preferred shared scheme. |
| `baselineXcodePath` | string | unset | Baseline Xcode application path to present for confirmation. |
| `candidateXcodePath` | string | unset | Candidate Xcode application path to present for confirmation. |
| `sdkIdentifiers` | string array | `[]` | SDK identifiers such as `iphoneos` or `macosx`. Values must contain letters, digits, `_`, or `-`. |
| `activeCompilationConditions` | string array | `[]` | Additional Swift compilation conditions using Swift identifier syntax. |
| `excludedPaths` | string array | `[]` | Paths excluded from project discovery. |
| `minimumSeverity` | enum | `notice` | Minimum finding severity: `notice`, `warning`, or `error`. |
| `minimumConfidence` | enum | `medium` | Minimum finding confidence: `low`, `medium`, or `high`. |
| `ciFailureLevel` | enum | `error` | Failure threshold retained by the core result evaluator. |
| `outputFormat` | enum | `terminal` | Default report format: `terminal`, `json`, or `sarif`. |

Duplicate SDK identifiers or compilation conditions are rejected. Unknown or malformed data produces a field-specific setup error; SwiftDelta does not silently reinterpret it.

## TUI settings

Application settings use format version `1` and are stored at:

```text
~/Library/Application Support/SwiftDelta/settings.json
```

Writes use a sibling temporary file, atomic replacement, a `0700` application directory, and a `0600` settings file. Missing, truncated, invalid, or newer unsupported settings are ignored with a warning and safe defaults.

`swiftdelta --safe-mode` ignores settings and history for that launch without deleting either file.

### Workflow defaults

The TUI persists the effective values you choose, including:

- project and optional configuration path;
- workspace or project container, scheme, and build configuration;
- destination, selected Xcodes, and SDK identifiers;
- compilation conditions and exclusions;
- finding severity and confidence thresholds;
- uncertain-finding inclusion;
- operation timeout (`900` seconds by default) and Doctor timeout (`60` seconds);
- failure threshold and incomplete-result handling;
- progress quiet mode;
- SDK cache policy;
- report and repair-plan formats and paths;
- repair file and identifier filters;
- on-device model timeout and candidate limit when that capability is available.

The runtime availability check, not the stored legacy enablement field, decides whether Apple Foundation Models is available. Unsupported model controls are hidden.

### Appearance and interaction

Settings include optional color and symbol modes, high contrast, reduced motion, mouse input, contextual help, and history. Terminal capability detection supplies defaults when a mode is not overridden. `NO_COLOR` disables color presentation.

### Privacy defaults

Recent-project history is disabled by default. Remembering recent projects and retaining operation summaries require explicit settings. SwiftDelta does not persist source code, model source context, full compiler logs, repair staging data, secrets, or temporary project copies.

History uses format version `1` and, when enabled, is stored at:

```text
~/Library/Application Support/SwiftDelta/history.json
```

Settings provides confirmed actions to clear settings or history. These actions do not modify project configuration.

## SDK cache

Persistent normalized SDK module snapshots live at:

```text
~/Library/Caches/org.swiftdelta/SDKSnapshots/v1
```

The cache policy can be `use`, `refresh`, or `disabled`. Settings can show entry count, invalid count, size, and date range. Pruning requires a maximum age, maximum size, or both; invalid entries are also selected. Clearing and pruning operate only on regular `.json` entries inside SwiftDelta's canonical cache root and never follow symlinks.

Cache age and size limits are optional and must be nonnegative. See [Analysis](Analysis.md#snapshot-cache) for identity and integrity rules.

## Setup origins and invalidation

The TUI distinguishes automatically discovered values, project configuration, saved selections, explicit manual choices, values requiring attention, and invalid values. Resetting one field to automatic selection reruns only the dependent discovery.

Changing a container, scheme, configuration, Xcode, SDK, destination, platform, architecture, deployment target, or compilation condition invalidates Doctor, Analysis, and Repair evidence tied to the old context. It does not delete exported reports or persistent SDK snapshots; their embedded identities remain unchanged.

## Export paths

Reports and repair plans are written only after an explicit export action. A missing path opens a focused input sheet with a suggested filename; input is validated before the operation resumes. SwiftDelta does not write reports, plans, logs, or UI settings into the analyzed project merely because that project was selected.
