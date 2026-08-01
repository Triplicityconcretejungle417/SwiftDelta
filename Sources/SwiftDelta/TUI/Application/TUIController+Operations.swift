//===--- TUIController+Operations.swift - SwiftDelta ------------------------------------------===//
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

extension TUIController {
    func confirm(_ action: TUIConfirmation) {
        switch action {
        case .quit:
            coordinator.cancel()
            state.shouldQuit = true
        case .applyRepairs:
            start(.applyRepair)
        case .clearCache:
            start(.cacheClear)
        case .pruneCache:
            guard state.settings.cache.maximumAgeDays != nil
                    || state.settings.cache.maximumSizeMiB != nil
            else {
                state.overlay = .message(
                    title: "Cache limits required",
                    message:
                        "Set a maximum age, maximum size, or both before pruning.",
                    details: nil
                )
                return
            }
            start(.cachePrune)
        case .clearHistory:
            do {
                try settingsStore.clearHistory()
                state.history = TUIHistory()
            } catch {
                showStorageError(error)
            }
        case .clearSettings:
            do {
                try settingsStore.clearSettings()
                let projectRoot = state.settings.workflow.projectRoot
                state.settings = TUISettings()
                state.settings.workflow.projectRoot = projectRoot
                state.setupOrigins = [:]
                state.selectedContainer = nil
                if state.projectWasExplicitlySelected {
                    start(.automaticSetup)
                }
            } catch {
                showStorageError(error)
            }
        case .cancelOperation:
            coordinator.cancel()
        }
    }

    func start(_ kind: TUIOperationKind) {
        guard !coordinator.isRunning() else {
            state.overlay = .message(
                title: "Operation already running",
                message:
                    "Cancel or wait for the current operation before starting another.",
                details: nil
            )
            return
        }
        if kind == .planRepair {
            refreshFoundationModelStatus()
        }
        if kind == .validateRepair {
            guard let candidate = state.selectedRepairCandidate,
                  !state.effectiveRepairIdentifiers(for: candidate).isEmpty
                    || state.draft(for: candidate) != nil
            else {
                state.overlay = .message(
                    title: "No proposal to validate",
                    message:
                        "Select a repair candidate that contains exact source "
                        + "edits, then open it and choose validation.",
                    details: nil
                )
                return
            }
        }
        if let input = requiredInput(for: kind) {
            state.overlay = .requiredInput(input)
            return
        }
        if kind == .doctor, !state.setupIsReady {
            state.pendingOperation = kind
            state.requestedSetupField = nextMissingSetupField()
            start(.automaticSetup)
            return
        }
        if (kind == .scan || kind == .compare), !state.doctorPassed {
            state.overlay = .message(
                title: "Run Doctor first",
                message:
                    "Analysis requires a successful Doctor validation for the current setup.",
                details: nil
            )
            return
        }
        let request = TUIOperationRequest(
            settings: state.settings,
            report: state.report,
            repairPlan: state.repairPlan,
            selectedRepairIdentifiers:
                kind == .validateRepair
                ? Set(state.selectedRepairCandidate.map {
                    state.effectiveRepairIdentifiers(for: $0)
                } ?? [])
                : state.selectedRepairIDs,
            validatedRepairIdentifiers: state.validatedRepairIDs,
            repairCandidateIdentifier:
                kind == .validateRepair
                ? state.selectedRepairCandidate?.candidateIdentifier : nil,
            repairDraft:
                kind == .validateRepair
                ? state.selectedRepairCandidate.flatMap {
                    state.draft(for: $0)
                } : nil,
            requestedSetupField: state.requestedSetupField,
            foundationModelStatus: state.foundationModelStatus
        )
        if kind == .validateRepair {
            state.validatingRepairCandidateID =
                state.selectedRepairCandidate?.candidateIdentifier
        }
        if coordinator.start(kind, request: request),
           kind == .automaticSetup
        {
            state.requestedSetupField = nil
        }
    }

    private func requiredInput(
        for kind: TUIOperationKind
    ) -> TUIRequiredInput? {
        let projectOperations: Set<TUIOperationKind> = [
            .discover, .scan, .compare, .doctor, .planRepair, .applyRepair,
            .validateRepair, .exportReport, .exportRepairPlan,
        ]
        if projectOperations.contains(kind),
           !state.projectWasExplicitlySelected
        {
            return TUIRequiredInput(
                title: "Choose a project",
                message:
                    "Enter the root directory of the project or package. "
                    + "SwiftDelta will inspect it and continue \(kind.title.lowercased()).",
                field: .projectRoot,
                value: state.settings.workflow.projectRoot,
                validationMessage: nil,
                pendingOperation: kind
            )
        }
        if kind == .exportReport,
           state.settings.workflow.reportOutputPath?.isEmpty != false
        {
            let fileExtension = switch state.settings.workflow.reportFormat {
            case .terminal: "txt"
            case .json: "json"
            case .sarif: "sarif"
            }
            return TUIRequiredInput(
                title: "Export analysis report",
                message:
                    "Choose where to write the completed "
                    + "\(state.settings.workflow.reportFormat.rawValue) report.",
                field: .reportOutput,
                value: defaultOutputPath(
                    filename: "SwiftDelta-report.\(fileExtension)"
                ),
                validationMessage: nil,
                pendingOperation: kind
            )
        }
        if kind == .exportRepairPlan,
           state.settings.workflow.repairOutputPath?.isEmpty != false
        {
            let fileExtension =
                state.settings.workflow.repairPlanFormat == .json
                ? "json" : "diff"
            return TUIRequiredInput(
                title: "Export repair plan",
                message:
                    "Choose where to write the current repair preview. "
                    + "No source file will be modified.",
                field: .repairOutput,
                value: defaultOutputPath(
                    filename: "SwiftDelta-repair-plan.\(fileExtension)"
                ),
                validationMessage: nil,
                pendingOperation: kind
            )
        }
        return nil
    }

    private func defaultOutputPath(filename: String) -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent(filename)
            .path
    }

    private func nextMissingSetupField() -> TUISetupField? {
        if state.selectedContainer == nil { return .container }
        if state.selectedContainer?.kind != .package,
           state.settings.workflow.scheme?.isEmpty != false
        {
            return .scheme
        }
        if state.settings.workflow.buildConfiguration?.isEmpty != false {
            return .buildConfiguration
        }
        if state.settings.workflow.baselineXcodePath?.isEmpty != false
            || state.setupOrigins[.baselineXcode] != .saved
        {
            return .baselineXcode
        }
        if state.settings.workflow.candidateXcodePath?.isEmpty != false
            || state.setupOrigins[.candidateXcode] != .saved
        {
            return .candidateXcode
        }
        if state.settings.workflow.sdkIdentifiers.isEmpty
            || state.settings.workflow.destination?.isEmpty != false
            || state.setupOrigins[.sdk] != .saved
            || state.setupOrigins[.destination] != .saved
        {
            return .sdk
        }
        return nil
    }

    func accept(_ result: TUIOperationResult) {
        switch result {
        case let .automaticSetup(result):
            let previousIdentity = setupIdentity(state.settings.workflow)
            state.settings.workflow = result.workflow
            state.discovery = result.discovery
            state.selectedContainer = result.selectedContainer
            state.setupOrigins = result.origins
            state.setupNotes = result.notes
            let setupChanged = setupIdentity(result.workflow) != previousIdentity
            if setupChanged {
                invalidateDownstreamEvidence()
            }
            if let resolution = result.resolution {
                state.overlay = .setupResolution(resolution)
            } else if state.setupIsReady,
                      setupChanged || state.doctorResult == nil
            {
                // Setup completion is the one point where environment
                // validation is automatic. Analysis and source changes still
                // require explicit user actions.
                state.pendingOperation = .doctor
            }
            saveSettings()
        case let .discovery(discovery):
            state.discovery = discovery
        case let .report(report):
            state.report = report
            state.repairPlan = nil
            state.repairFindingDispositions = []
            state.repairCandidates = []
            state.activeRepairCandidateIdentifier = nil
            state.repairDrafts = []
            state.repairCoverage = nil
            state.foundationModelPlanningSummary = nil
            state.validatedRepairCandidateIDs = []
            state.validatedRepairIDs = []
            state.validatedCandidateRepairIdentifiers = [:]
            state.repairValidationMessages = [:]
            state.repairValidationSuccessMessages = [:]
            state.repairValidationSkippedMessages = [:]
            state.staleRepairCandidateIDs = []
            state.validatingRepairCandidateID = nil
            state.selectedRepairIDs = []
            selectScreen(.findings)
            state.contentIndex = report.findings.isEmpty
                ? 0 : TUIContentRows.resultControlCount(for: state)
        case let .doctor(result):
            state.doctorResult = result
            if state.advanceAfterSetup, result.issues.isEmpty {
                state.advanceAfterSetup = false
                selectScreen(.check)
            } else if !result.issues.isEmpty {
                state.advanceAfterSetup = false
            }
        case let .repairPlan(output):
            acceptRepairPlan(output)
        case let .preparedRepairPlan(prepared):
            acceptRepairPlan(prepared.output)
            state.validatedRepairCandidateIDs =
                prepared.validatedCandidateIdentifiers
            state.validatedCandidateRepairIdentifiers =
                prepared.repairIdentifiersByCandidate
            state.validatedRepairIDs = Set(
                prepared.repairIdentifiersByCandidate.values.flatMap { $0 }
            )
            state.repairValidationSuccessMessages = prepared.successMessages
            state.repairValidationMessages = prepared.failureMessages
            state.repairValidationSkippedMessages = prepared.skippedMessages
        case let .repairValidated(
            candidateIdentifier,
            repairs,
            message
        ):
            let combined = Dictionary(
                ((state.repairPlan?.repairs ?? []) + repairs).map {
                    ($0.repairIdentifier, $0)
                },
                uniquingKeysWith: { _, latest in latest }
            ).values.sorted {
                $0.repairIdentifier < $1.repairIdentifier
            }
            let rebuilt = RepairPlanBuilder.build(
                projectRoot: URL(
                    fileURLWithPath: state.settings.workflow.projectRoot
                ),
                repairs: combined,
                planningFailures:
                    state.repairPlan?.planningFailures ?? [],
                generatedAt: state.repairPlan?.generatedAt ?? Date()
            )
            state.repairPlan = rebuilt
            let repairIdentifiers = Set(repairs.map(\.repairIdentifier))
            state.validatedRepairCandidateIDs.insert(candidateIdentifier)
            state.validatedCandidateRepairIdentifiers[
                candidateIdentifier
            ] = repairIdentifiers
            state.validatedRepairIDs.formUnion(repairIdentifiers)
            state.repairValidationMessages[candidateIdentifier] = nil
            state.repairValidationSkippedMessages[candidateIdentifier] = nil
            state.repairValidationSuccessMessages[candidateIdentifier] =
                message
            state.validatingRepairCandidateID = nil
        case .repairsApplied:
            // Candidate verification already rebuilds and repeats target-aware
            // repair evidence analysis. Do not keep the pre-repair Analysis
            // report visible after source has changed.
            state.report = nil
            state.repairPlan = nil
            state.repairFindingDispositions = []
            state.repairCandidates = []
            state.activeRepairCandidateIdentifier = nil
            state.repairDrafts = []
            state.repairCoverage = nil
            state.foundationModelPlanningSummary = nil
            state.selectedRepairIDs = []
            state.validatedRepairCandidateIDs = []
            state.validatedRepairIDs = []
            state.validatedCandidateRepairIdentifiers = [:]
            state.repairValidationMessages = [:]
            state.repairValidationSuccessMessages = [:]
            state.repairValidationSkippedMessages = [:]
            state.staleRepairCandidateIDs = []
            state.validatingRepairCandidateID = nil
        case let .reportExported(path), let .repairPlanExported(path):
            state.lastExportPath = path
        case let .cacheStatus(status):
            state.cacheStatus = status
        case let .cacheChanged(_, status):
            state.cacheStatus = status
        }
    }

    private func acceptRepairPlan(_ output: RepairPlanningOutput) {
        let plan = output.plan
        state.repairPlan = plan
        state.repairFindingDispositions = output.findingDispositions
        state.repairCandidates = output.repairCandidates
        state.repairDrafts = output.repairDrafts
        state.repairCoverage = output.repairCoverage
        state.foundationModelPlanningSummary = output.foundationModelSummary
        // Preview and validation never imply consent to modify source.
        // Ready repairs remain unselected until the user presses Space.
        state.selectedRepairIDs = []
        state.validatedRepairCandidateIDs = []
        state.validatedRepairIDs = []
        state.validatedCandidateRepairIdentifiers = [:]
        state.repairValidationMessages = [:]
        state.repairValidationSuccessMessages = [:]
        state.repairValidationSkippedMessages = [:]
        state.staleRepairCandidateIDs = []
        state.validatingRepairCandidateID = nil
        state.activeRepairCandidateIdentifier =
            state.displayedRepairCandidates.first?.candidateIdentifier
    }

    func completionMessage(
        _ kind: TUIOperationKind,
        result: TUIOperationResult
    ) -> String {
        switch result {
        case let .automaticSetup(value):
            if let resolution = value.resolution {
                return "Setup needs \(resolution.field.rawValue)."
            }
            return "Project setup completed."
        case let .discovery(value):
            return "Discovered \(value.containers.count) container(s) and "
                + "\(value.swiftFiles.count) Swift file(s)."
        case let .report(report):
            return resultLabel(report)
                + " · \(report.findings.count) finding(s)"
        case let .doctor(value):
            return value.issues.isEmpty
                ? "Doctor completed without reported issues."
                : "Doctor completed with \(value.issues.count) issue(s)."
        case let .repairPlan(output):
            let plan = output.plan
            return "Generated \(plan.repairs.count) repair proposal(s), "
                + "\(plan.conflicts.count) conflict(s) for "
                + "\(output.repairCoverage.findingsReceived) finding(s)."
        case let .preparedRepairPlan(prepared):
            let ready = prepared.validatedCandidateIdentifiers.count
            let failed = prepared.failureMessages.count
            return "Generated and automatically validated repair proposals · "
                + "\(ready) Ready · \(failed) failed validation."
        case .repairValidated:
            return "Validated the candidate repair in an isolated project copy."
        case let .repairsApplied(count):
            return "Applied and verified \(count) repair(s)."
        case let .reportExported(path):
            return "Exported report to \(path)."
        case let .repairPlanExported(path):
            return "Exported repair plan to \(path)."
        case let .cacheStatus(status):
            return "Cache contains \(status.entryCount) entries."
        case let .cacheChanged(message, _):
            return message
        }
    }

    func resultLabel(_ report: AnalysisReport) -> String {
        switch report.analysisState {
        case .completeAndClean:
            return "PASS"
        case .completeWithFindings:
            let failure = report.findings.contains {
                $0.severity.isAtLeast(state.settings.workflow.failureLevel)
            }
            return failure ? "FAIL" : "PASS"
        case .incomplete:
            return state.settings.workflow.allowIncomplete
                ? "INCOMPLETE (allowed)" : "INCOMPLETE"
        case .blocked:
            return "BLOCKED"
        }
    }

    func confirmationOverlay(
        for action: TUIConfirmation
    ) -> TUIOverlay {
        switch action {
        case .applyRepairs:
            return .confirmation(
                title: "Apply Selected Repairs?",
                message:
                    "SwiftDelta will stage exact edits, verify with the candidate "
                    + "Xcode, and roll back every file if verification fails.",
                action: action
            )
        case .clearCache:
            return .confirmation(
                title: "Clear SDK cache?",
                message:
                    "Only SwiftDelta-owned SDK snapshot entries will be removed.",
                action: action
            )
        case .pruneCache:
            return .confirmation(
                title: "Prune SDK cache?",
                message:
                    "Entries outside the configured age or size limits will be removed.",
                action: action
            )
        case .clearHistory:
            return .confirmation(
                title: "Clear project history?",
                message: "Stored recent paths and operation summaries will be removed.",
                action: action
            )
        case .clearSettings:
            return .confirmation(
                title: "Reset application settings?",
                message:
                    "UI preferences will be removed. Project configuration is untouched.",
                action: action
            )
        case .quit, .cancelOperation:
            return .none
        }
    }

}
