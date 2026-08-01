# Terminal interface

Running `swiftdelta` opens the full-screen application. Home is the navigation hub: select a project, complete setup, run Doctor, move to Analysis, then review Repair.

## Launch behavior

```text
swiftdelta [--safe-mode] [--project <path>]
swiftdelta --help
swiftdelta --version
```

`-h` and `-V` are short forms for help and version. Normal launch requires a TTY or PTY. Unknown arguments and former operational commands exit with status `2` and a concise explanation.

`--project` preselects an accessible directory and starts asynchronous setup discovery inside the TUI. Doctor can follow automatically once setup is complete. Analysis and Repair still require their normal TUI actions. `--safe-mode` uses default settings and no history for the current launch.

## Home and setup

Home shows:

- the current project;
- baseline and candidate Xcode;
- selected scheme, configuration, platform, SDK, and destination;
- Doctor, Analysis, and Repair state;
- the next available action;
- secondary Settings, Help, About, and recent projects when enabled.

Project inspection runs asynchronously. SwiftDelta can select an unambiguous associated container, shared scheme, and configuration. It does not assign Xcode roles or a material platform context automatically.

The Xcode sheet shows version, build, path, installed SDKs, and current role. Equivalent builds cannot fill both roles. **Other Xcode…** accepts a path only after bundle validation.

The platform sheet contains only contexts supported by the selected scheme and targets. A selection such as **iOS Device** or **Mac Catalyst** assigns its SDK and destination together.

**Customize Setup ›** shows every effective field and its origin. It is a destination, not a toggle. Selection sheets preserve existing values until a replacement is confirmed. Missing or ambiguous values open a focused sheet at the point an operation needs them.

Doctor remains disabled until project root, container, required scheme, configuration, both Xcodes, platform, SDK, and destination are ready. A setup change marks dependent evidence stale.

## Doctor

Doctor validates only the selected environment. It reports concise checks for project and container validity, Xcode identities and trust, required tools, SDK and destination, deployment context, local dependencies, writable temporary and cache roots, and recognizable scripts, plugins, macros, generators, or custom build rules.

Technical paths, version output, and signature details remain in the detail view. Doctor contains no Analysis mode, report export, or Repair controls. **Continue to Analysis** navigates without starting Analysis.

## Analysis

Before a result exists, Analysis contains mode selection, advanced controls, and **Run Analysis**. After completion, the same screen contains:

- `PASS`, `FAIL`, `INCOMPLETE`, or `BLOCKED`;
- findings with grouping, sorting, severity filtering, and search;
- separate baseline and candidate coverage;
- operational analysis issues;
- report format, path, and export;
- rerun and **Continue to Repair**.

Wide terminals place the selected finding's structured evidence beside the list. Narrower terminals open the same content as a scrollable detail view. Focus never enters a hidden pane.

## Repair

Repair owns preview planning, Draft editing, isolated validation, candidate inspection, repair-plan export, selection, Apply, final verification, and rollback. Entering with current Analysis evidence can start bounded planning and validation automatically; it never selects or applies an edit.

The repair funnel reads **Findings → Actionable → Proposed → Validated → Ready → Selected**. Filters keep Ready, validating, review, failed, no-fix, and all dispositions accessible.

On wide terminals, the left pane lists candidates and the right pane shows the selected Diff, evidence, validation, and risks. Narrower terminals open that inspector as a large scrollable view. Focus and selected-for-Apply state remain distinct.

Visible actions include **Edit Draft**, **Validate Again**, **Select Repair**, plan export, and **Apply Selected Repairs**. Apply stays disabled until at least one conflict-free Ready repair is selected.

## Missing values and sheets

An action that needs a path or selection opens the corresponding sheet rather than exposing an internal error. This includes project and Xcode paths, platform context, report output, source scope, and repair-plan input or output.

Sheets explain the requested value, show discovered choices or a safe suggested path, validate input inline, and resume the interrupted action after confirmation. Escape cancels without changing the prior value.

## Keyboard and mouse reference

| Input | Action |
| --- | --- |
| Up / Down | Move through visible rows or choices. |
| Left / Right | Change a value or scroll a Diff horizontally. |
| Enter | Open or activate the focused item. |
| Space | Toggle a setting or select a Ready repair. |
| Tab / Shift-Tab | Move between visible focus areas. |
| Escape | Close a view, return, or request cancellation. |
| Page Up / Page Down | Scroll lists, details, and sheets. |
| Home / End | Move to the first or last item. |
| `/` | Edit finding search. |
| `g` | Cycle finding grouping. |
| `s` | Cycle finding sorting. |
| `f` | Cycle finding severity filter. |
| `E` in Repair | Open the selected Draft editor. |
| `V` in Repair | Validate the selected proposal again. |
| `p` during planning | Pause or resume at a safe planning boundary. |
| `l` | Open operation technical details. |
| `?` | Open contextual help. |
| `q` | Open quit confirmation. |

A single mouse click focuses a row; a double-click activates it. Wheel input scrolls the active list or detail. Mouse support is optional and can be disabled without losing an operation.

## Layout and terminal capabilities

Wide layouts begin at 120 columns and can use two panes. Medium and narrow layouts use compact composition and drill-down details. The minimum supported viewport is 64 columns by 18 rows; smaller terminals show a resize requirement without drawing outside the bounds.

Resize recomputes layout, focus, and scroll position. Long paths, Unicode source names, and diagnostics are clipped or wrapped by display width rather than byte count.

SwiftDelta uses the terminal's default background. It adapts to True Color, 256-color, basic color, monochrome, high contrast, `NO_COLOR`, Unicode, and ASCII modes. Full-row focus remains distinguishable without relying on color. Reduced Motion replaces animated progress with a static state.

## Progress and logs

Long work uses one bounded panel with the active phase, elapsed time, completed phases, recent meaningful updates, and a compact Swift transition animation. A one-row solid progress bar shows measured completion when a total exists; unknown work uses a restrained indeterminate state without an invented percentage.

Only the most specific active child operation owns the heartbeat. Raw subprocess output is available in technical details and does not overwrite the main screen.

## Cancellation and terminal restoration

Escape requests operation cancellation. Ctrl-C cancels active work; without active work it exits. SIGTERM, SIGHUP, and SIGQUIT request cancellation, stop child processes, clean temporary artifacts, restore terminal state, and exit.

The terminal session owns raw input, alternate-screen state, cursor visibility, mouse reporting, and styles. Cleanup is idempotent after normal exit, cancellation, supported signals, partial startup, and thrown errors. `SIGKILL` cannot be handled.

If an external force-kill leaves the terminal altered, run:

```sh
stty sane
printf '\033[?25h\033[?1049l\033[0m'
```

All external text is sanitized before rendering. Filenames, diagnostics, SDK declarations, logs, and model output cannot inject ANSI, OSC, clipboard, title, or cursor-control sequences.
