//===--- TUIContentRows.swift - SwiftDelta ------------------------------------------===//
//
// This source file is part of the SwiftDelta open source project
//
// Copyright (c) 2026 Jiaxu Li
// Licensed under the Apache License, Version 2.0
//
// See LICENSE for license information
//
//===----------------------------------------------------------------------===//

import Foundation
import SwiftDeltaCore

struct TUIRow: Sendable {
    let label: String
    let value: String
    let detail: String
    let action: TUIRowAction
    var enabled = true
    var prominence = TUIRowProminence.standard
    var section: TUIRowSection?
}

enum TUIRowProminence: Sendable {
    case standard
    case primary
    case destructive
    case destination
    case secondary
}

enum TUIRowSection: String, Sendable {
    case project = "Project"
    case actions = "Actions"
    case other = "Other"
}

enum TUIRowAction: Sendable {
    case none
    case navigate(TUIScreen)
    case showHelp
    case showAbout
    case showDoctorDetails
    case showRepairDisposition(String)
    case editSelectedRepairDraft
    case toggleSelectedRepair
    case repairSelectedFinding
    case selectRecentProject(String)
    case edit(TUIEditableField)
    case chooseSetup(TUISetupField)
    case toggle(TUIToggle)
    case cycle(TUICycle)
    case operation(TUIOperationKind)
    case confirmation(TUIConfirmation)
}

enum TUIToggle: Sendable {
    case advancedOptions
    case includeUncertain
    case allowIncomplete
    case quietProgress
    case mouse
    case highContrast
    case reducedMotion
    case contextualHelp
    case history
    case rememberProjects
    case operationSummaries
}

enum TUICycle: Sendable {
    case compatibilityCheck
    case resultsView
    case findingSeverity
    case findingGrouping
    case findingSort
    case settingsSection
    case minimumSeverity
    case minimumConfidence
    case failureLevel
    case cachePolicy
    case reportFormat
    case repairPlanFormat
    case repairFilter
    case foundationModelReasoning
    case colorMode
    case symbolMode
}

enum TUIContentRows {
    static let resultControlCount = 10

    static func resultControlCount(for state: TUIState) -> Int {
        resultControls(for: state).count
    }

    static func rows(for state: TUIState) -> [TUIRow] {
        switch state.screen {
        case .project:
            project(state)
        case .setup:
            setup(state)
        case .check:
            check(state)
        case .findings:
            resultControls(for: state)
        case .repair:
            repair(state)
        case .settings:
            settings(state)
        }
    }

    static func displayedRowIndices(for rows: [TUIRow]) -> [Int?] {
        var result: [Int?] = []
        var currentSection: TUIRowSection?
        for index in rows.indices {
            if let section = rows[index].section,
               section != currentSection
            {
                result.append(nil)
                currentSection = section
            }
            result.append(index)
        }
        return result
    }

    private static func project(_ state: TUIState) -> [TUIRow] {
        let value = state.settings.workflow
        let hasProject = state.projectWasExplicitlySelected
        let setupReady = state.setupIsReady
        let projectDetail: String
        if let container = state.selectedContainer {
            let context = [
                container.kind == .package
                    ? "Swift Package" : container.kind.rawValue.capitalized,
                value.scheme,
                value.sdkIdentifiers.first,
                value.destination,
            ].compactMap { $0 }
            projectDetail = context.joined(separator: " · ")
        } else if case .running(.automaticSetup, _) = state.operationStatus {
            projectDetail = "Detecting container, scheme, SDK, and destination."
        } else {
            projectDetail =
                "Select a directory containing Package.swift, an Xcode "
                + "project, or a workspace."
        }
        var rows = [
            TUIRow(
            label: hasProject ? "Selected project" : "Choose project",
            value: state.projectWasExplicitlySelected
                ? value.projectRoot : "Enter a directory",
            detail: projectDetail,
            action: .edit(.projectRoot),
            prominence: hasProject ? .standard : .primary,
            section: .project
            ),
            setupChoice(
                "Baseline Xcode",
                xcodeDisplay(
                    role: "Baseline",
                    path: value.baselineXcodePath,
                    doctor: state.doctorResult
                ),
                .baselineXcode,
                 "Toolchain and SDK used as the starting point."),
            setupChoice(
                "Candidate Xcode",
                xcodeDisplay(
                    role: "Candidate",
                    path: value.candidateXcodePath,
                    doctor: state.doctorResult
                ),
                .candidateXcode,
                 "Toolchain and SDK being evaluated."),
            TUIRow(
                label: "Customize Setup",
                value: "›",
                detail:
                    "Review detected values or override a specific selection.",
                action: .navigate(.setup),
                prominence: hasProject && !setupReady ? .primary : .secondary
            ),
        ]
        rows[1].enabled = hasProject
        rows[2].enabled = hasProject
        rows[3].enabled = hasProject
        if hasProject, value.baselineXcodePath == nil {
            rows[1].prominence = .primary
        } else if hasProject, value.candidateXcodePath == nil {
            rows[2].prominence = .primary
        }
        let doctorValue: String
        if let doctor = state.doctorResult {
            doctorValue = doctor.issues.isEmpty
                ? (doctor.notes.isEmpty ? "Ready" : "Ready · \(doctor.notes.count) note(s)")
                : "\(doctor.issues.count) issue(s)"
        } else {
            doctorValue = "Check project and toolchains"
        }
        let primaryAction: TUIScreen = state.repairPlan != nil
            ? .repair
            : (state.report != nil ? .findings : .check)
        let missing = state.missingSetupRequirements
        rows.append(contentsOf: [
            TUIRow(
                label: "Doctor",
                value: doctorValue,
                detail: setupReady
                    ? "Validate the selected project, Xcodes, SDK, and destination."
                    : "Complete setup: \(missing.joined(separator: ", ")).",
                action: .navigate(.check),
                enabled: hasProject && setupReady,
                prominence: hasProject && setupReady
                    && primaryAction == .check ? .primary : .destination,
                section: .actions
            ),
            TUIRow(
                label: "Analysis",
                value: state.report.map {
                    "\($0.findings.count) finding(s) · \($0.analysisState.rawValue)"
                } ?? "Run after Doctor passes",
                detail: "Configure, run, and review compatibility analysis.",
                action: .navigate(.findings),
                enabled: state.doctorPassed || state.report != nil,
                prominence: primaryAction == .findings
                    ? .primary : .destination
            ),
            TUIRow(
                label: "Repair",
                value: state.repairPlan.map {
                    "\($0.repairs.count) proposal(s)"
                } ?? (state.report == nil
                    ? "Analysis required" : "Review repair options"),
                detail: "Preview conservative repairs and verify selected changes.",
                action: .navigate(.repair),
                enabled: state.report != nil || state.repairPlan != nil,
                prominence: primaryAction == .repair
                    ? .primary : .destination
            ),
            TUIRow(
                label: "Settings",
                value: "Appearance, privacy, cache",
                detail: "Application preferences and maintenance.",
                action: .navigate(.settings),
                prominence: .secondary,
                section: .other
            ),
            TUIRow(
                label: "Help",
                value: "Navigation and workflow",
                detail: "Show keyboard and mouse controls.",
                action: .showHelp,
                prominence: .secondary
            ),
            TUIRow(
                label: "About",
                value: "Version, license, documentation",
                detail: "View application information.",
                action: .showAbout,
                prominence: .secondary
            ),
        ])
        let recent = state.history.entries
            .sorted { $0.openedAt > $1.openedAt }
            .prefix(5)
        rows.append(contentsOf: recent.map {
            TUIRow(
                label: "Recent",
                value: $0.projectPath,
                detail: "Select this project without starting an operation.",
                action: .selectRecentProject($0.projectPath),
                prominence: .secondary
            )
        })
        return rows
    }

    private static func setup(_ state: TUIState) -> [TUIRow] {
        let value = state.settings.workflow
        let container = value.workspacePath ?? value.projectPath
            ?? state.selectedContainer?.path
        return [
            edit(
                "Configuration file",
                value.configurationPath,
                .configurationPath,
                "Optional existing .swiftdelta.json path; it remains read-only."
            ),
            setupChoice(
                "Project container",
                container,
                field: .container,
                state: state,
                detail: "Choose among discovered projects, workspaces, or packages."
            ),
            setupChoice(
                "Scheme",
                value.scheme,
                field: .scheme,
                state: state,
                detail: "Shared scheme defining targets and source membership."
            ),
            setupChoice(
                "Build configuration",
                value.buildConfiguration,
                field: .buildConfiguration,
                state: state,
                detail: "Effective Xcode build configuration."
            ),
            setupChoice(
                "Platform",
                platformDisplay(value),
                field: .sdk,
                state: state,
                detail: "Choose a supported platform; SDK and destination move together."
            ),
            setupChoice(
                "Baseline Xcode",
                value.baselineXcodePath,
                field: .baselineXcode,
                state: state,
                detail: "Older toolchain and SDK used as the baseline."
            ),
            setupChoice(
                "Candidate Xcode",
                value.candidateXcodePath,
                field: .candidateXcode,
                state: state,
                detail: "Newer toolchain and SDK being evaluated."
            ),
            edit(
                "Compilation conditions",
                value.activeCompilationConditions.joined(separator: ", "),
                .compilationConditions,
                "Additional active Swift compilation conditions."
            ),
            edit(
                "Excluded paths",
                value.excludedPaths.joined(separator: ", "),
                .excludedPaths,
                "Project-relative discovery exclusions."
            ),
            edit(
                "Inspection timeout",
                format(value.doctorTimeout),
                .doctorTimeout,
                "Seconds available to each read-only setup phase."
            ),
            TUIRow(
                label: "Detect setup again",
                value: "Refresh",
                detail:
                    "Revalidate automatic values while retaining valid saved selections.",
                action: .operation(.automaticSetup),
                prominence: .primary
            ),
        ]
    }

    private static func check(_ state: TUIState) -> [TUIRow] {
        let value = state.settings.workflow
        var rows: [TUIRow] = [
            TUIRow(
                label: "Validation",
                value: state.doctorResult.map {
                    $0.issues.isEmpty
                        ? "Ready"
                        : "\($0.issues.count) issue(s)"
                } ?? "Not run",
                detail: state.doctorResult?.issues.first
                    ?? state.doctorResult?.notes.first
                    ?? "Validate the selected project and toolchains before analysis.",
                action: state.doctorResult == nil ? .none : .showDoctorDetails
            ),
            TUIRow(
                label: state.doctorResult == nil ? "Run Doctor" : "Run Doctor Again",
                value: state.setupIsReady
                    ? "Validate setup" : "Setup incomplete",
                detail: "Repeat the read-only validation after changing setup.",
                action: .operation(.doctor),
                enabled: state.setupIsReady,
                prominence: .primary
            ),
            TUIRow(
                label: "Project",
                value: URL(fileURLWithPath: value.projectRoot).lastPathComponent,
                detail: value.workspacePath ?? value.projectPath
                    ?? "Container detected from the selected directory.",
                action: .navigate(.project)
            ),
            TUIRow(
                label: "Xcodes",
                value: [
                    xcodeDisplay(
                        role: "Baseline",
                        path: value.baselineXcodePath,
                        doctor: state.doctorResult
                    ),
                    xcodeDisplay(
                        role: "Candidate",
                        path: value.candidateXcodePath,
                        doctor: state.doctorResult
                    ),
                ].compactMap { $0 }.joined(separator: "  →  "),
                detail:
                    "Baseline and candidate remain isolated through explicit "
                    + "developer directories.",
                action: .navigate(.project)
            ),
            TUIRow(
                label: "Build context",
                value: [
                    value.scheme ?? "automatic scheme",
                    value.buildConfiguration ?? "default configuration",
                    value.destination ?? "default destination",
                ].joined(separator: " · "),
                detail: "Target membership, SDK, destination, and deployment target stay aligned.",
                action: .navigate(.project)
            ),
        ]
        if state.doctorPassed {
            rows.append(
                TUIRow(
                    label: "Continue to Analysis",
                    value: "›",
                    detail:
                        "Open analysis setup without starting work automatically.",
                    action: .navigate(.findings),
                    prominence: .primary
                )
            )
        }
        return rows
    }

    static func resultControls(for state: TUIState) -> [TUIRow] {
        let workflow = state.settings.workflow
        var rows = [
            cycle(
                "Analysis mode",
                state.compatibilityCheck.rawValue,
                .compatibilityCheck,
                state.compatibilityCheck == .sdkAnalysis
                    ? "Compare SDK declarations referenced by selected targets."
                    : "Compare SDK evidence and isolated builds with both Xcodes."
            ),
            toggle(
                "Customize Analysis",
                state.advancedOptionsExpanded,
                .advancedOptions,
                "Thresholds, uncertainty, timeouts, completeness, cache, and export."
            ),
            TUIRow(
                label: state.report == nil ? "Run Analysis" : "Run Analysis Again",
                value: state.compatibilityCheck == .sdkAnalysis
                    ? "SDK analysis" : "SDK and build comparison",
                detail: "Runs with the setup validated by Doctor.",
                action: .operation(
                    state.compatibilityCheck == .sdkAnalysis ? .scan : .compare
                ),
                enabled: state.doctorPassed,
                prominence: .primary
            ),
        ]
        if state.advancedOptionsExpanded {
            rows.append(contentsOf: [
                cycle("Minimum severity", workflow.minimumSeverity.rawValue,
                      .minimumSeverity, "Filter SDK and compiler findings by severity."),
                cycle("Minimum confidence", workflow.minimumConfidence.rawValue,
                      .minimumConfidence, "Keep confidence distinct from compiler severity."),
                toggle("Include uncertain findings", workflow.includeUncertain,
                       .includeUncertain, "Include explicitly low-confidence unresolved evidence."),
                edit("Operation timeout", format(workflow.timeout), .timeout,
                     "Seconds for compiler and SDK extraction operations."),
                cycle("Failure threshold", workflow.failureLevel.rawValue,
                      .failureLevel, "Controls PASS or FAIL classification and exported reports."),
                toggle("Allow incomplete results", workflow.allowIncomplete,
                       .allowIncomplete, "Show threshold status despite incomplete coverage."),
                toggle("Quiet progress", workflow.progressQuiet, .quietProgress,
                       "Suppress nonessential progress details."),
                cycle("SDK cache policy", workflow.sdkCachePolicy.rawValue,
                      .cachePolicy, "Use, refresh, or disable the SDK snapshot cache."),
            ])
        }
        guard state.report != nil else {
            return rows
        }
        rows.append(contentsOf: [
            cycle("View", state.resultsView.rawValue, .resultsView,
                  "Findings, coverage, or analysis issues."),
            edit("Search", state.search, .search,
                 "Filter findings by title, location, module, or identifier."),
            cycle("Severity", state.severityFilter?.rawValue ?? "all",
                  .findingSeverity, "Show all findings or one compiler severity."),
            cycle("Group by", state.grouping.rawValue, .findingGrouping,
                  "Group findings with visible headers and counts."),
            cycle("Sort by", state.sorting.rawValue, .findingSort,
                  "Choose a stable order inside each group."),
            TUIRow(
                label: "Export",
                value: workflow.reportFormat.rawValue,
                detail: workflow.reportOutputPath.map {
                    "Write the completed report to \($0)."
                } ?? "Choose an output path and write the completed report.",
                action: .operation(.exportReport),
                enabled: true,
                prominence: .primary
            ),
            TUIRow(
                label: "Continue to Repair",
                value: "›",
                detail: "Open Repair without generating or applying a plan.",
                action: .navigate(.repair),
                prominence: .primary
            ),
        ])
        if state.advancedOptionsExpanded {
            rows.insert(contentsOf: [
                cycle("Report format", workflow.reportFormat.rawValue,
                      .reportFormat, "Terminal, native JSON, or SARIF."),
                edit("Report output", workflow.reportOutputPath, .reportOutput,
                     "Explicit output path for the completed result."),
            ], at: rows.count - 2)
        }
        return rows
    }

    private static func repair(_ state: TUIState) -> [TUIRow] {
        let value = state.settings.workflow
        var rows = [
            cycle("Preview format", value.repairPlanFormat.rawValue,
                  .repairPlanFormat, "Unified diff or versioned JSON repair plan."),
            TUIRow(
                label: "Generate Repair Preview",
                value: "Generate plan",
                detail: "Collect exact evidence and build a plan without modifying source.",
                action: .operation(.planRepair),
                prominence: .primary
            ),
            toggle(
                "Customize repair",
                state.advancedOptionsExpanded,
                .advancedOptions,
                "File scope, plan loading, identifiers, and advanced repair controls."
            ),
        ]
        if state.advancedOptionsExpanded {
            var advancedRows = [
                edit("Selected source files", value.repairSourcePaths.joined(separator: ", "),
                     .repairFiles, "Optional project-relative scope; unselected files cannot be modified."),
                edit("Repair identifiers", value.repairIdentifiers.joined(separator: ", "),
                     .repairIdentifiers, "Optional stable repair identifiers to select."),
                edit("Finding identifiers", value.findingIdentifiers.joined(separator: ", "),
                     .findingIdentifiers, "Optional finding identifiers to select."),
                edit("Load repair plan", value.repairPlanInputPath, .repairPlanInput,
                     "Load a versioned plan; source fingerprints are still validated."),
                edit("Repair-plan output", value.repairOutputPath, .repairOutput,
                     "Explicit path used only when the plan is exported."),
            ]
            if state.foundationModelStatus.isAvailable {
                advancedRows.append(
                    TUIRow(
                        label: "Apple Foundation Models",
                        value:
                            state.foundationModelStatus.hostModelGeneration
                            ?? "On-device",
                        detail:
                            "Used automatically after deterministic repair "
                            + "strategies are exhausted.",
                        action: .none,
                        enabled: false
                    )
                )
                if state.foundationModelStatus.reasoningLevel != "unsupported" {
                    advancedRows.append(
                        cycle(
                            "Reasoning level",
                            value.foundationModelReasoning?.rawValue
                                ?? state.foundationModelStatus.reasoningLevel,
                            .foundationModelReasoning,
                            "Only levels supported by the local on-device model are used."
                        )
                    )
                }
                advancedRows.append(
                    edit(
                        "Model timeout",
                        format(value.foundationModelTimeout),
                        .foundationModelTimeout,
                        "Overall seconds available to the bounded on-device model stage."
                    )
                )
                advancedRows.append(
                    edit(
                        "Model candidate limit",
                        String(
                            value.foundationModelCandidateLimit
                                ?? FoundationModelRepairOptions
                                    .hardMaximumCandidates
                        ),
                        .foundationModelCandidateLimit,
                        "Prioritized findings to process; maximum "
                            + "\(FoundationModelRepairOptions.hardMaximumCandidates)."
                    )
                )
            }
            rows.insert(contentsOf: advancedRows, at: 1)
        }
        if let plan = state.repairPlan {
            if let coverage = state.repairCoverage {
                let funnel = state.repairFunnel
                rows.append(
                    TUIRow(
                        label: "Repair funnel",
                        value:
                            "\(funnel.findings) Findings → "
                            + "\(funnel.actionable) Actionable → "
                            + "\(funnel.proposed) Proposed",
                        detail:
                            "\(funnel.validated) Validated → "
                            + "\(funnel.ready) Ready → "
                            + "\(funnel.selected) Selected. "
                            + "\(coverage.conflicting) conflict · "
                            + "\(coverage.planningFailures) planning failure(s).",
                        action: .none,
                        enabled: false
                    )
                )
                rows.append(
                    cycle(
                        "Show repairs",
                        state.repairFilter.rawValue,
                        .repairFilter,
                        "Actionable is the default. Ready, Review, Failed, "
                            + "No Fix, and All retain every disposition."
                    )
                )
                rows.append(
                    TUIRow(
                        label: "Coverage details",
                        value:
                            "\(plan.repairs.count) planned · "
                            + "\(coverage.mechanicallyRepairable) mechanical · "
                            + "\(coverage.modelProposed) model",
                        detail:
                            "\(coverage.reviewOnly) review · "
                            + "\(coverage.unsupported) no safe fix · "
                            + "\(coverage.conflicting) conflicting.",
                        action: .none,
                        enabled: false
                    )
                )
            }
            if let summary = state.foundationModelPlanningSummary,
               summary.unavailable == 0
            {
                rows.append(
                    TUIRow(
                        label: "On-device model planning",
                        value:
                            "\(summary.processed) processed · "
                            + "\(summary.drafted) draft(s) · "
                            + "\(summary.convertedIntoRepairs) repair(s) · "
                            + "\(summary.rejected) rejected",
                        detail:
                            "\(summary.findingsConsidered) considered · "
                            + "\(summary.skipped) insufficient evidence · "
                            + "\(summary.deduplicated) deduplicated · "
                            + "\(summary.deferredByLimit) deferred by limit · "
                            + "\(summary.timedOut) timed out · "
                            + "\(summary.cancelled) cancelled.",
                        action: .none,
                        enabled: false
                    )
                )
            }
            let dispositionGroups: [TUIRepairDispositionGroup] = switch state.repairFilter {
            case .review:
                state.repairDispositionGroups.filter {
                    $0.kind == .manualReviewRequired
                        || $0.kind == .foundationModelsProposal
                }
            case .failed:
                state.repairDispositionGroups.filter(\.hasConflict)
            case .noFix:
                state.repairDispositionGroups.filter {
                    $0.kind == .notRepairable
                }
            case .all:
                state.repairDispositionGroups
            case .actionable, .ready, .validating:
                []
            }
            rows.append(contentsOf: dispositionGroups.map {
                dispositionRow($0)
            })
            let visiblePlanningFailures =
                state.repairFilter == .failed || state.repairFilter == .all
                ? plan.planningFailures : []
            rows.append(contentsOf: visiblePlanningFailures.map { failure in
                let presentation = planningFailurePresentation(failure)
                return TUIRow(
                    label: presentation.label,
                    value: presentation.value,
                    detail: failure.message,
                    action: .none,
                    enabled: false
                )
            })
            let selectedCandidate = state.activeRepairCandidate
            let selectedDraft = selectedCandidate.flatMap(state.draft(for:))
            let canValidate = selectedCandidate.map {
                !state.effectiveRepairIdentifiers(for: $0).isEmpty
                    || selectedDraft != nil
            } ?? false
            rows.append(
                TUIRow(
                    label: "Edit Draft",
                    value: selectedDraft == nil ? "Unavailable" : "Open editor",
                    detail: selectedDraft == nil
                        ? "Select a retained on-device model draft first."
                        : "Edit exact anchors or proposed source; validation remains required.",
                    action: .editSelectedRepairDraft,
                    enabled: selectedDraft != nil,
                    prominence: .secondary
                )
            )
            rows.append(
                TUIRow(
                    label: "Validate Again",
                    value: canValidate ? "Isolated candidate build" : "Unavailable",
                    detail: canValidate
                        ? "Re-anchor, parse, resolve, and verify the selected proposal again."
                        : "Select a proposal containing an exact source edit first.",
                    action: .operation(.validateRepair),
                    enabled: canValidate,
                    prominence: .primary
                )
            )
            let canSelect = selectedCandidate.map(
                state.candidateIsSelectable
            ) ?? false
            let isSelected = selectedCandidate.map {
                let identifiers = Set(
                    state.effectiveRepairIdentifiers(for: $0)
                )
                return !identifiers.isEmpty
                    && identifiers.isSubset(of: state.selectedRepairIDs)
            } ?? false
            rows.append(
                TUIRow(
                    label: isSelected ? "Deselect Repair" : "Select Repair",
                    value: isSelected ? "Selected" : (canSelect ? "Ready" : "Unavailable"),
                    detail: repairSelectionReason(
                        selectedCandidate,
                        state: state,
                        canSelect: canSelect
                    ),
                    action: .toggleSelectedRepair,
                    enabled: canSelect,
                    prominence: .primary
                )
            )
            rows.append(
                TUIRow(
                    label: "Export repair plan",
                    value: "\(plan.repairs.count) repair(s)",
                    detail: plan.repairs.isEmpty
                        ? "No source edits are available to export."
                        : "Write the currently displayed diff or JSON plan.",
                    action: .operation(.exportRepairPlan),
                    enabled: !plan.repairs.isEmpty,
                    prominence: .primary
                )
            )
            rows.append(
                TUIRow(
                    label: "Apply Selected Repairs",
                    value: "\(state.selectedRepairIDs.count) selected",
                    detail: state.selectedRepairIDs.isEmpty
                        ? "Select at least one applicable, conflict-free repair first."
                        : "Explicit confirmation, transactional writes, candidate verification, "
                            + "and complete rollback on failure.",
                    action: .confirmation(.applyRepairs),
                    enabled: !state.selectedRepairIDs.isEmpty,
                    prominence: .primary
                )
            )
        }
        switch state.operationStatus {
        case let .succeeded(.applyRepair, message):
            rows.append(
                TUIRow(
                    label: "Verification",
                    value: "Passed",
                    detail: message,
                    action: .none,
                    enabled: false
                )
            )
        case let .failed(.applyRepair, summary, details):
            rows.append(
                TUIRow(
                    label: "Verification",
                    value: "Failed · no verified change",
                    detail: details.isEmpty ? summary : details,
                    action: .none,
                    enabled: false
                )
            )
        default:
            break
        }
        return rows
    }

    private static func repairSelectionReason(
        _ candidate: RepairCandidatePresentation?,
        state: TUIState,
        canSelect: Bool
    ) -> String {
        guard let candidate else {
            return "Select a repair proposal first."
        }
        if canSelect {
            return state.candidateNeedsSemanticReview(candidate)
                ? "Review the behavior-sensitive diff before selection; Apply remains verified and transactional."
                : "Space is an optional accelerator; Apply remains explicit and transactional."
        }
        let identifiers = Set(state.effectiveRepairIdentifiers(for: candidate))
        if !identifiers.isDisjoint(with: state.repairConflictIdentifiers) {
            return "This proposal overlaps or contradicts another source edit."
        }
        switch state.repairLifecycle(for: candidate) {
        case .planning:
            return "Repair evidence is still being collected."
        case .validating:
            return "Isolated candidate-Xcode validation is still running."
        case .needsReview:
            return "The proposal must pass isolated validation before selection."
        case .noSafeFix:
            return "No exact source edit is available for this finding."
        case .failed:
            return "Validation or a structural safety check failed."
        case .stale:
            return "The source changed after planning; generate a new preview."
        case .ready:
            return "The proposal has no applicable repair identifier."
        }
    }

    private static func planningFailurePresentation(
        _ failure: AnalysisFailure
    ) -> (label: String, value: String) {
        let message = failure.message.lowercased()
        let label: String
        if message.contains("model") && message.contains("unavailable") {
            label = "Model unavailable"
        } else if message.contains("structured output") {
            label = "Invalid model response"
        } else if message.contains("context")
            && message.contains("exceed")
        {
            label = "Model context too large"
        } else if message.contains("timed out") {
            label = "Model timed out"
        } else if message.contains("cancelled") {
            label = "Model generation cancelled"
        } else if message.contains("generation") {
            label = "Generation failed"
        } else if message.contains("ambiguous") {
            label = "Ambiguous source edit"
        } else if message.contains("fragment")
            || message.contains("source anchor")
        {
            label = "Invalid source anchor"
        } else if message.contains("rejected")
            || message.contains("not accepted")
        {
            label = "Safety rejection"
        } else if message.contains("verif") {
            label = "Verification failure"
        } else {
            label = "Repair evidence issue"
        }
        let value = failure.location.map {
            let line = $0.line.map { ":\($0)" } ?? ""
            return "\($0.path)\(line)"
        } ?? "Needs review"
        return (label, value)
    }

    private static func dispositionRow(
        _ group: TUIRepairDispositionGroup
    ) -> TUIRow {
        let label: String
        let value: String
        switch group.kind {
        case .automaticallySafe:
            label = "Safe repair"
            value = group.title
        case .foundationModelsProposal:
            label = "Foundation Models"
            value = group.title
        case .manualReviewRequired:
            label = group.hasConflict ? "Conflict" : "Review required"
            value = group.title
        case .notRepairable:
            label = group.isInformational
                ? "Information only" : "Not repairable"
            value = group.title
        }
        return TUIRow(
            label: group.dispositions.count == 1
                ? label : "\(label) ×\(group.dispositions.count)",
            value: value,
            detail: group.reason,
            action: .showRepairDisposition(group.identifier)
        )
    }

    private static func settings(_ state: TUIState) -> [TUIRow] {
        var rows = [
            cycle(
                "Section",
                state.settingsSection.rawValue,
                .settingsSection,
                "General, appearance, privacy, cache, or application information."
            ),
        ]
        switch state.settingsSection {
        case .general:
            rows.append(contentsOf: [
                toggle("Mouse input", state.settings.interaction.mouseEnabled,
                       .mouse, "Enable clicking and wheel scrolling on the next launch."),
                toggle("Contextual action help",
                       state.settings.interaction.showContextualHelp,
                       .contextualHelp, "Show concise actions in the footer."),
            ])
        case .appearance:
            rows.append(contentsOf: Array(applicationSettings(state.settings).prefix(4)))
        case .privacy:
            rows.append(contentsOf: Array(applicationSettings(state.settings).dropFirst(6)))
        case .cache:
            rows.append(contentsOf: cache(state))
        case .about:
            rows.append(contentsOf: [
                TUIRow(
                    label: "SwiftDelta",
                    value: SwiftDeltaVersion.current,
                    detail: "Compares Apple-platform projects across local Xcode SDKs.",
                    action: .none,
                    enabled: false
                ),
                TUIRow(
                    label: "Author and project owner",
                    value: "Jiaxu Li",
                    detail: "SwiftDelta is an open-source project.",
                    action: .none,
                    enabled: false
                ),
                TUIRow(
                    label: "Copyright",
                    value: "© 2026 Jiaxu Li",
                    detail: "Copyright for the SwiftDelta open-source project.",
                    action: .none,
                    enabled: false
                ),
                TUIRow(
                    label: "Website",
                    value: "https://jiaxuli.com",
                    detail: "Project and author information.",
                    action: .none,
                    enabled: false
                ),
                TUIRow(
                    label: "License",
                    value: "Apache License 2.0",
                    detail: "See LICENSE in the source distribution.",
                    action: .none,
                    enabled: false
                ),
                TUIRow(
                    label: "Repair safety",
                    value: "Preview, verify, then apply",
                    detail: "Failed verification rolls selected source files back.",
                    action: .none,
                    enabled: false
                ),
                TUIRow(
                    label: "Privacy",
                    value: "Local by design",
                    detail: "SwiftDelta does not intentionally send project source over the network.",
                    action: .none,
                    enabled: false
                ),
                TUIRow(
                    label: "Contributing",
                    value: "Contributions welcome",
                    detail: "See CONTRIBUTING.md for development and review guidance.",
                    action: .none,
                    enabled: false
                ),
            ])
        }
        return rows
    }

    private static func cache(_ state: TUIState) -> [TUIRow] {
        [
            TUIRow(
                label: "SDK snapshot cache",
                value: state.cacheStatus.map {
                    "\($0.entryCount) entries · \($0.byteCount) bytes"
                } ?? "Not inspected",
                detail: state.cacheStatus?.root
                    ?? "SwiftDelta-owned SDK metadata only; no project source.",
                action: .operation(.cacheStatus)
            ),
            edit("Maximum age", state.settings.cache.maximumAgeDays.map(format),
                 .cacheMaximumAge, "Days; leave empty for no age limit."),
            edit("Maximum size", state.settings.cache.maximumSizeMiB.map(format),
                 .cacheMaximumSize, "MiB; leave empty for no size limit."),
            TUIRow(
                label: "Prune cache",
                value: "Confirm",
                detail: "Remove only SwiftDelta SDK cache entries outside the selected limits.",
                action: .confirmation(.pruneCache)
            ),
            TUIRow(
                label: "Clear cache",
                value: "Confirm",
                detail: "Remove all SwiftDelta-owned SDK snapshot cache entries.",
                action: .confirmation(.clearCache)
            ),
        ]
    }

    private static func applicationSettings(_ value: TUISettings) -> [TUIRow] {
        [
            cycle("Color mode",
                  value.appearance.colorMode?.rawValue ?? "automatic",
                  .colorMode, "Automatic, True Color, 256 colors, basic, or monochrome."),
            cycle("Symbol mode",
                  value.appearance.symbolMode?.rawValue ?? "automatic",
                  .symbolMode, "Unicode navigation symbols or an ASCII fallback."),
            toggle("High contrast", value.appearance.highContrast,
                   .highContrast, "Increase text contrast and reduce color dependence."),
            toggle("Reduced motion", value.appearance.reducedMotion,
                   .reducedMotion, "Disable decorative animation; progress remains textual."),
            toggle("Mouse input", value.interaction.mouseEnabled,
                   .mouse, "Enable clicking and wheel scrolling on the next launch."),
            toggle("Contextual shortcut help", value.interaction.showContextualHelp,
                   .contextualHelp, "Keep concise keyboard guidance in the footer."),
            toggle("History", value.interaction.historyEnabled,
                   .history, "Allow optional privacy-conscious project history."),
            toggle("Remember recent projects", value.privacy.rememberRecentProjects,
                   .rememberProjects, "Store project paths only when history is enabled."),
            toggle("Retain operation summaries", value.privacy.retainOperationSummaries,
                   .operationSummaries, "Store operation names and outcomes, never diagnostics or source."),
            TUIRow(
                label: "Clear history",
                value: "Confirm",
                detail: "Remove SwiftDelta's local project history.",
                action: .confirmation(.clearHistory)
            ),
            TUIRow(
                label: "Reset settings",
                value: "Confirm",
                detail: "Remove stored UI settings without touching project configuration.",
                action: .confirmation(.clearSettings)
            ),
        ]
    }

    private static func edit(
        _ label: String,
        _ value: String?,
        _ field: TUIEditableField,
        _ detail: String
    ) -> TUIRow {
        TUIRow(
            label: label,
            value: value?.isEmpty == false ? value! : "Not set",
            detail: detail,
            action: .edit(field)
        )
    }

    private static func setupChoice(
        _ label: String,
        _ value: String?,
        field setupField: TUISetupField,
        state: TUIState,
        detail: String
    ) -> TUIRow {
        let origin = state.setupOrigins[setupField] ?? (
            value == nil || value?.isEmpty == true ? .attention : .saved
        )
        let originLabel = switch origin {
        case .automatic: "Automatic"
        case .saved: "Saved"
        case .attention: "Needs attention"
        }
        return TUIRow(
            label: label,
            value: [value.flatMap { $0.isEmpty ? nil : $0 }, originLabel]
                .compactMap { $0 }.joined(separator: " · "),
            detail: detail,
            action: .chooseSetup(setupField),
            prominence: origin == .attention ? .primary : .standard
        )
    }

    private static func setupChoice(
        _ label: String,
        _ value: String?,
        _ setupField: TUISetupField,
        _ detail: String
    ) -> TUIRow {
        TUIRow(
            label: label,
            value: value?.isEmpty == false ? value! : "Choose…",
            detail: detail,
            action: .chooseSetup(setupField),
            prominence: value?.isEmpty == false ? .standard : .primary
        )
    }

    private static func platformDisplay(
        _ workflow: TUIWorkflowSettings
    ) -> String? {
        guard let sdk = workflow.sdkIdentifiers.first,
              let destination = workflow.destination
        else {
            return nil
        }
        let label: String
        if destination.contains("Mac Catalyst") {
            label = "Mac Catalyst"
        } else {
            label = switch sdk {
            case "iphoneos": "iOS Device"
            case "iphonesimulator": "iOS Simulator"
            case "macosx": "macOS"
            case "appletvos": "tvOS Device"
            case "appletvsimulator": "tvOS Simulator"
            case "watchos": "watchOS Device"
            case "watchsimulator": "watchOS Simulator"
            case "xros": "visionOS Device"
            case "xrsimulator": "visionOS Simulator"
            default: sdk
            }
        }
        return "\(label) · \(sdk) · \(destination)"
    }

    private static func toggle(
        _ label: String,
        _ value: Bool,
        _ toggle: TUIToggle,
        _ detail: String
    ) -> TUIRow {
        TUIRow(
            label: label,
            value: value ? "On" : "Off",
            detail: detail,
            action: .toggle(toggle)
        )
    }

    private static func cycle(
        _ label: String,
        _ value: String,
        _ cycle: TUICycle,
        _ detail: String
    ) -> TUIRow {
        TUIRow(
            label: label,
            value: value,
            detail: detail,
            action: .cycle(cycle)
        )
    }

    private static func format(_ value: Double) -> String {
        value.rounded() == value
            ? String(Int(value))
            : String(format: "%.2f", value)
    }

    private static func xcodeDisplay(
        role: String,
        path: String?,
        doctor: TUIDoctorResult?
    ) -> String? {
        let prefix = "\(role) Xcode: "
        if let identity = doctor?.lines.first(where: {
            $0.hasPrefix(prefix)
        }) {
            return String(identity.dropFirst(prefix.count))
        }
        guard let path else { return nil }
        let info = URL(fileURLWithPath: path)
            .appendingPathComponent("Contents/Info.plist")
        if let data = try? Data(contentsOf: info, options: [.mappedIfSafe]),
           let values = try? PropertyListSerialization.propertyList(
               from: data,
               format: nil
           ) as? [String: Any]
        {
            let version = values["CFBundleShortVersionString"] as? String
            let build = values["DTXcodeBuild"] as? String
                ?? values["CFBundleVersion"] as? String
            if let version, let build {
                return "Xcode \(version) (\(build)) · \(path)"
            }
        }
        return path
    }
}
