//===--- TUIController+Settings.swift - SwiftDelta ------------------------------------------===//
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
    func commit(field: TUIEditableField, value: String) {
        do {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            switch field {
            case .projectRoot:
                let expanded = NSString(string: trimmed).expandingTildeInPath
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(
                    atPath: expanded,
                    isDirectory: &isDirectory
                ), isDirectory.boolValue else {
                    throw LaunchError(
                        "The project root is not an accessible directory."
                    )
                }
                invalidateDownstreamEvidence()
                state.settings.workflow.projectRoot = URL(
                    fileURLWithPath: expanded
                ).standardizedFileURL.resolvingSymlinksInPath().path
                state.report = nil
                state.repairPlan = nil
                state.repairFindingDispositions = []
                state.repairCoverage = nil
                state.foundationModelPlanningSummary = nil
                state.discovery = nil
                state.doctorResult = nil
                state.selectedContainer = nil
                state.setupNotes = []
                state.projectWasExplicitlySelected = true
                clearProjectSetupSelections()
                recordProjectOpen()
            case .configurationPath:
                invalidateDownstreamEvidence()
                state.settings.workflow.configurationPath = optional(trimmed)
            case .workspacePath:
                invalidateDownstreamEvidence()
                state.settings.workflow.workspacePath = optional(trimmed)
                if !trimmed.isEmpty {
                    state.settings.workflow.projectPath = nil
                }
            case .projectPath:
                invalidateDownstreamEvidence()
                state.settings.workflow.projectPath = optional(trimmed)
                if !trimmed.isEmpty {
                    state.settings.workflow.workspacePath = nil
                }
            case .scheme:
                invalidateDownstreamEvidence()
                state.settings.workflow.scheme = optional(trimmed)
            case .buildConfiguration:
                invalidateDownstreamEvidence()
                state.settings.workflow.buildConfiguration = optional(trimmed)
            case .destination:
                invalidateDownstreamEvidence()
                state.settings.workflow.destination = optional(trimmed)
            case .baselineXcode:
                let path = try validatedXcodePath(
                    trimmed,
                    other: state.settings.workflow.candidateXcodePath
                )
                invalidateDownstreamEvidence()
                state.settings.workflow.baselineXcodePath = path
            case .candidateXcode:
                let path = try validatedXcodePath(
                    trimmed,
                    other: state.settings.workflow.baselineXcodePath
                )
                invalidateDownstreamEvidence()
                state.settings.workflow.candidateXcodePath = path
            case .sdkIdentifiers:
                invalidateDownstreamEvidence()
                state.settings.workflow.sdkIdentifiers = list(trimmed)
            case .compilationConditions:
                state.settings.workflow.activeCompilationConditions = list(
                    trimmed
                )
            case .excludedPaths:
                state.settings.workflow.excludedPaths = list(trimmed)
            case .timeout:
                state.settings.workflow.timeout = try positiveNumber(
                    trimmed,
                    field: "operation timeout"
                )
            case .doctorTimeout:
                state.settings.workflow.doctorTimeout = try positiveNumber(
                    trimmed,
                    field: "doctor timeout"
                )
            case .reportOutput:
                state.settings.workflow.reportOutputPath = optional(trimmed)
            case .repairFiles:
                state.settings.workflow.repairSourcePaths = list(trimmed)
            case .repairIdentifiers:
                state.settings.workflow.repairIdentifiers = list(trimmed)
            case .findingIdentifiers:
                state.settings.workflow.findingIdentifiers = list(trimmed)
            case .repairPlanInput:
                state.settings.workflow.repairPlanInputPath = optional(trimmed)
            case .repairOutput:
                state.settings.workflow.repairOutputPath = optional(trimmed)
            case .foundationModelTimeout:
                state.settings.workflow.foundationModelTimeout =
                    try positiveNumber(
                        trimmed,
                        field: "Foundation Models timeout"
                    )
            case .foundationModelCandidateLimit:
                guard let value = Int(trimmed),
                      (1...FoundationModelRepairOptions.hardMaximumCandidates)
                        .contains(value)
                else {
                    throw LaunchError(
                        "The Foundation Models candidate limit must be between "
                            + "1 and "
                            + "\(FoundationModelRepairOptions.hardMaximumCandidates)."
                    )
                }
                state.settings.workflow.foundationModelCandidateLimit = value
            case .cacheMaximumAge:
                state.settings.cache.maximumAgeDays = try optionalNonnegative(
                    trimmed,
                    field: "maximum cache age"
                )
            case .cacheMaximumSize:
                state.settings.cache.maximumSizeMiB = try optionalNonnegative(
                    trimmed,
                    field: "maximum cache size"
                )
            case .search:
                state.search = trimmed
                state.contentIndex = 0
            }
            recordManualSetupSelection(field, value: trimmed)
            state.overlay = .none
            saveSettings()
            if field.affectsAutomaticSetup {
                start(.automaticSetup)
            }
        } catch {
            state.overlay = .message(
                title: "Invalid value",
                message: error.localizedDescription,
                details: nil
            )
        }
    }

    func setToggle(_ toggle: TUIToggle) {
        switch toggle {
        case .advancedOptions:
            state.advancedOptionsExpanded.toggle()
            state.contentIndex = 0
        case .includeUncertain:
            state.settings.workflow.includeUncertain.toggle()
        case .allowIncomplete:
            state.settings.workflow.allowIncomplete.toggle()
        case .quietProgress:
            state.settings.workflow.progressQuiet.toggle()
        case .mouse:
            state.settings.interaction.mouseEnabled.toggle()
        case .highContrast:
            state.settings.appearance.highContrast.toggle()
        case .reducedMotion:
            state.settings.appearance.reducedMotion.toggle()
        case .contextualHelp:
            state.settings.interaction.showContextualHelp.toggle()
        case .history:
            state.settings.interaction.historyEnabled.toggle()
        case .rememberProjects:
            state.settings.privacy.rememberRecentProjects.toggle()
        case .operationSummaries:
            state.settings.privacy.retainOperationSummaries.toggle()
        }
        saveSettings()
    }

    func setCycle(_ cycle: TUICycle, forward: Bool) {
        switch cycle {
        case .compatibilityCheck:
            state.compatibilityCheck = cycled(
                state.compatibilityCheck,
                values: TUICompatibilityCheck.allCases,
                forward: forward
            )
        case .resultsView:
            state.resultsView = cycled(
                state.resultsView,
                values: TUIResultsView.allCases,
                forward: forward
            )
            state.contentIndex = 0
        case .findingSeverity:
            let values: [Severity?] = [nil, .error, .warning, .notice]
            state.severityFilter = cycledOptional(
                state.severityFilter,
                values: values,
                forward: forward
            )
            state.contentIndex = 0
        case .findingGrouping:
            state.grouping = cycled(
                state.grouping,
                values: FindingGrouping.allCases,
                forward: forward
            )
            state.contentIndex = 0
        case .findingSort:
            state.sorting = cycled(
                state.sorting,
                values: FindingSort.allCases,
                forward: forward
            )
            state.contentIndex = 0
        case .settingsSection:
            state.settingsSection = cycled(
                state.settingsSection,
                values: TUISettingsSection.allCases,
                forward: forward
            )
            state.contentIndex = 0
        case .minimumSeverity:
            state.settings.workflow.minimumSeverity = cycled(
                state.settings.workflow.minimumSeverity,
                values: [.notice, .warning, .error],
                forward: forward
            )
        case .minimumConfidence:
            state.settings.workflow.minimumConfidence = cycled(
                state.settings.workflow.minimumConfidence,
                values: [.low, .medium, .high],
                forward: forward
            )
        case .failureLevel:
            state.settings.workflow.failureLevel = cycled(
                state.settings.workflow.failureLevel,
                values: [.notice, .warning, .error],
                forward: forward
            )
        case .cachePolicy:
            state.settings.workflow.sdkCachePolicy = cycled(
                state.settings.workflow.sdkCachePolicy,
                values: [.use, .refresh, .disabled],
                forward: forward
            )
        case .reportFormat:
            state.settings.workflow.reportFormat = cycled(
                state.settings.workflow.reportFormat,
                values: [.terminal, .json, .sarif],
                forward: forward
            )
        case .repairPlanFormat:
            state.settings.workflow.repairPlanFormat = cycled(
                state.settings.workflow.repairPlanFormat,
                values: [.diff, .json],
                forward: forward
            )
        case .repairFilter:
            state.repairFilter = cycled(
                state.repairFilter,
                values: TUIRepairFilter.allCases,
                forward: forward
            )
            if !state.displayedRepairCandidates.contains(where: {
                $0.candidateIdentifier
                    == state.activeRepairCandidateIdentifier
            }) {
                state.activeRepairCandidateIdentifier =
                    state.displayedRepairCandidates.first?.candidateIdentifier
            }
            state.contentIndex = 0
        case .foundationModelReasoning:
            let values: [FoundationModelReasoningLevel?] = [
                nil, .light, .moderate, .deep,
            ]
            state.settings.workflow.foundationModelReasoning = cycledOptional(
                state.settings.workflow.foundationModelReasoning,
                values: values,
                forward: forward
            )
        case .colorMode:
            let values: [TerminalColorMode?] = [
                nil, .trueColor, .indexed256, .basic, .monochrome,
            ]
            state.settings.appearance.colorMode = cycledOptional(
                state.settings.appearance.colorMode,
                values: values,
                forward: forward
            )
        case .symbolMode:
            let values: [TerminalSymbolMode?] = [nil, .unicode, .ascii]
            state.settings.appearance.symbolMode = cycledOptional(
                state.settings.appearance.symbolMode,
                values: values,
                forward: forward
            )
        }
        saveSettings()
    }

    func editableValue(_ field: TUIEditableField) -> String {
        let workflow = state.settings.workflow
        return switch field {
        case .projectRoot: workflow.projectRoot
        case .configurationPath: workflow.configurationPath ?? ""
        case .workspacePath: workflow.workspacePath ?? ""
        case .projectPath: workflow.projectPath ?? ""
        case .scheme: workflow.scheme ?? ""
        case .buildConfiguration: workflow.buildConfiguration ?? ""
        case .destination: workflow.destination ?? ""
        case .baselineXcode: workflow.baselineXcodePath ?? ""
        case .candidateXcode: workflow.candidateXcodePath ?? ""
        case .sdkIdentifiers: workflow.sdkIdentifiers.joined(separator: ", ")
        case .compilationConditions:
            workflow.activeCompilationConditions.joined(separator: ", ")
        case .excludedPaths: workflow.excludedPaths.joined(separator: ", ")
        case .timeout: String(workflow.timeout)
        case .doctorTimeout: String(workflow.doctorTimeout)
        case .reportOutput: workflow.reportOutputPath ?? ""
        case .repairFiles: workflow.repairSourcePaths.joined(separator: ", ")
        case .repairIdentifiers:
            workflow.repairIdentifiers.joined(separator: ", ")
        case .findingIdentifiers:
            workflow.findingIdentifiers.joined(separator: ", ")
        case .repairPlanInput: workflow.repairPlanInputPath ?? ""
        case .repairOutput: workflow.repairOutputPath ?? ""
        case .foundationModelTimeout:
            String(workflow.foundationModelTimeout)
        case .foundationModelCandidateLimit:
            String(
                workflow.foundationModelCandidateLimit
                    ?? FoundationModelRepairOptions.hardMaximumCandidates
            )
        case .cacheMaximumAge:
            state.settings.cache.maximumAgeDays.map { String($0) } ?? ""
        case .cacheMaximumSize:
            state.settings.cache.maximumSizeMiB.map { String($0) } ?? ""
        case .search: state.search
        }
    }

    func saveSettings() {
        guard !state.safeMode else { return }
        do {
            var persisted = state.settings
            if !persisted.interaction.historyEnabled
                || !persisted.privacy.rememberRecentProjects
            {
                persisted.workflow.projectRoot =
                    FileManager.default.currentDirectoryPath
                persisted.workflow.configurationPath = nil
                persisted.workflow.workspacePath = nil
                persisted.workflow.projectPath = nil
                persisted.workflow.scheme = nil
                persisted.workflow.reportOutputPath = nil
                persisted.workflow.repairSourcePaths = []
                persisted.workflow.repairIdentifiers = []
                persisted.workflow.findingIdentifiers = []
                persisted.workflow.repairPlanInputPath = nil
                persisted.workflow.repairOutputPath = nil
            }
            try settingsStore.save(persisted)
        } catch {
            showStorageError(error)
        }
    }

    func resetAutomaticSelection(_ field: TUISetupField) {
        invalidateDownstreamEvidence()
        switch field {
        case .container:
            state.settings.workflow.projectPath = nil
            state.settings.workflow.workspacePath = nil
        case .scheme:
            state.settings.workflow.scheme = nil
        case .buildConfiguration:
            state.settings.workflow.buildConfiguration = nil
        case .destination:
            state.settings.workflow.destination = nil
        case .sdk:
            state.settings.workflow.sdkIdentifiers = []
        case .baselineXcode:
            state.settings.workflow.baselineXcodePath = nil
        case .candidateXcode:
            state.settings.workflow.candidateXcodePath = nil
        }
        state.setupOrigins.removeValue(forKey: field)
        state.settings.workflow.setupValueOrigins = encodedSetupOrigins()
        saveSettings()
        start(.automaticSetup)
    }

    func invalidateDownstreamEvidence() {
        state.doctorResult = nil
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
        state.lastExportPath = nil
    }

    func setupIdentity(_ workflow: TUIWorkflowSettings) -> String {
        [
            workflow.projectRoot,
            workflow.workspacePath ?? "",
            workflow.projectPath ?? "",
            workflow.scheme ?? "",
            workflow.buildConfiguration ?? "",
            workflow.baselineXcodePath ?? "",
            workflow.candidateXcodePath ?? "",
            workflow.sdkIdentifiers.joined(separator: ","),
            workflow.destination ?? "",
        ].joined(separator: "\u{1F}")
    }

    func validateXcodeChoice(_ path: String, other: String?) -> Bool {
        do {
            _ = try validatedXcodePath(path, other: other)
            return true
        } catch {
            state.overlay = .message(
                title: "Invalid Xcode selection",
                message: error.localizedDescription,
                details: path
            )
            return false
        }
    }

    private func validatedXcodePath(
        _ value: String,
        other: String?
    ) throws -> String? {
        guard !value.isEmpty else { return nil }
        let path = NSString(string: value).expandingTildeInPath
        _ = try XcodeInstallation.validate(applicationPath: path)
        if let other, !other.isEmpty {
            _ = try XcodeInstallation.validate(applicationPath: other)
            let selectedIdentity = xcodeBuildIdentity(path)
            let otherIdentity = xcodeBuildIdentity(other)
            let selectedURL = URL(fileURLWithPath: path)
                .standardizedFileURL.resolvingSymlinksInPath()
            let otherURL = URL(fileURLWithPath: other)
                .standardizedFileURL.resolvingSymlinksInPath()
            guard selectedURL != otherURL,
                  selectedIdentity != otherIdentity
            else {
                throw LaunchError(
                    "Baseline and candidate must use distinct Xcode versions or build numbers."
                )
            }
        }
        return URL(fileURLWithPath: path)
            .standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func xcodeBuildIdentity(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
            .appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              let values = try? PropertyListSerialization.propertyList(
                  from: data,
                  format: nil
              ) as? [String: Any]
        else {
            return path
        }
        return [
            values["CFBundleShortVersionString"] as? String,
            values["DTXcodeBuild"] as? String
                ?? values["CFBundleVersion"] as? String,
        ].compactMap { $0 }.joined(separator: "|")
    }

    private func recordManualSetupSelection(
        _ field: TUIEditableField,
        value: String
    ) {
        guard let setupField = field.setupField else { return }
        if value.isEmpty {
            state.setupOrigins.removeValue(forKey: setupField)
        } else {
            state.setupOrigins[setupField] = .saved
        }
        state.settings.workflow.setupValueOrigins = encodedSetupOrigins()
    }

    private func clearProjectSetupSelections() {
        state.settings.workflow.workspacePath = nil
        state.settings.workflow.projectPath = nil
        state.settings.workflow.scheme = nil
        state.settings.workflow.buildConfiguration = nil
        state.settings.workflow.destination = nil
        state.settings.workflow.sdkIdentifiers = []
        for field in [
            TUISetupField.container,
            .scheme,
            .buildConfiguration,
            .destination,
            .sdk,
        ] {
            state.setupOrigins.removeValue(forKey: field)
        }
        state.settings.workflow.setupValueOrigins = encodedSetupOrigins()
    }

    private func encodedSetupOrigins() -> [String: TUISetupValueOrigin] {
        Dictionary(uniqueKeysWithValues: state.setupOrigins.map {
            ($0.key.rawValue, $0.value)
        })
    }

    func recordProjectOpen() {
        guard !state.safeMode,
              state.settings.interaction.historyEnabled,
              state.settings.privacy.rememberRecentProjects
        else {
            return
        }
        let path = state.settings.workflow.projectRoot
        state.history.entries.removeAll { $0.projectPath == path }
        state.history.entries.insert(
            TUIHistoryEntry(
                projectPath: path,
                openedAt: Date(),
                lastOperation: nil,
                outcome: nil
            ),
            at: 0
        )
        if state.history.entries.count > 20 {
            state.history.entries.removeLast(
                state.history.entries.count - 20
            )
        }
        try? settingsStore.save(state.history)
    }

    func recordHistory(operation: String, outcome: String) {
        guard !state.safeMode,
              state.settings.interaction.historyEnabled,
              state.settings.privacy.rememberRecentProjects,
              state.settings.privacy.retainOperationSummaries
        else {
            return
        }
        let path = state.settings.workflow.projectRoot
        state.history.entries.removeAll { $0.projectPath == path }
        state.history.entries.insert(
            TUIHistoryEntry(
                projectPath: path,
                openedAt: Date(),
                lastOperation: operation,
                outcome: outcome
            ),
            at: 0
        )
        try? settingsStore.save(state.history)
    }

    func appendLog(_ text: String) {
        state.technicalLog.append(
            TerminalText.sanitize(text, preservingNewlines: true)
        )
        if state.technicalLog.count > 500 {
            state.technicalLog.removeFirst(state.technicalLog.count - 500)
        }
    }

    func showStorageError(_ error: Error) {
        state.overlay = .message(
            title: "Local settings error",
            message: error.localizedDescription,
            details:
                "The analyzed project was not modified. You may continue in this session."
        )
    }

    func optional(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }

    func list(_ value: String) -> [String] {
        value.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    func positiveNumber(
        _ value: String,
        field: String
    ) throws -> Double {
        guard let result = Double(value), result > 0 else {
            throw LaunchError("\(field) must be greater than zero.")
        }
        return result
    }

    func optionalNonnegative(
        _ value: String,
        field: String
    ) throws -> Double? {
        guard !value.isEmpty else { return nil }
        guard let result = Double(value), result >= 0 else {
            throw LaunchError("\(field) cannot be negative.")
        }
        return result
    }

    func next<T: Equatable>(_ value: T, in values: [T]) -> T {
        guard let index = values.firstIndex(of: value) else {
            return values[0]
        }
        return values[(index + 1) % values.count]
    }

    func nextOptional<T: Equatable>(
        _ value: T?,
        in values: [T?]
    ) -> T? {
        guard let index = values.firstIndex(where: { $0 == value }) else {
            return values[0]
        }
        return values[(index + 1) % values.count]
    }

    func cycled<T: Equatable>(
        _ value: T,
        values: [T],
        forward: Bool
    ) -> T {
        guard let index = values.firstIndex(of: value) else {
            return values[0]
        }
        let delta = forward ? 1 : values.count - 1
        return values[(index + delta) % values.count]
    }

    func cycledOptional<T: Equatable>(
        _ value: T?,
        values: [T?],
        forward: Bool
    ) -> T? {
        guard let index = values.firstIndex(where: { $0 == value }) else {
            return values[0]
        }
        let delta = forward ? 1 : values.count - 1
        return values[(index + delta) % values.count]
    }}
