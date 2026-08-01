//===--- TUIState.swift - SwiftDelta ------------------------------------------===//
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

enum TUIScreen: String, CaseIterable, Sendable {
    case project
    case setup
    case check
    case findings
    case repair
    case settings

    var title: String {
        switch self {
        case .project: "Home"
        case .setup: "Customize Setup"
        case .check: "Doctor"
        case .findings: "Analysis"
        case .repair: "Repair"
        case .settings: "Settings"
        }
    }

    var navigationTitle: String {
        switch self {
        case .project: "Home"
        case .setup: "Customize Setup"
        case .check: "Doctor"
        case .findings: "Analysis"
        case .repair: "Repair"
        case .settings: "Settings"
        }
    }

    func symbol(ascii: Bool) -> String {
        if ascii {
            switch self {
            case .project: return "1"
            case .setup: return "-"
            case .check: return "2"
            case .findings: return "3"
            case .repair: return "4"
            case .settings: return "-"
            }
        }
        switch self {
        case .project: return "1"
        case .setup: return "·"
        case .check: return "2"
        case .findings: return "3"
        case .repair: return "4"
        case .settings: return "·"
        }
    }
}

enum TUIFocus: Sendable {
    case navigation
    case content
    case details
}

enum TUILayoutMode: Equatable, Sendable {
    case narrow
    case medium
    case wide

    init(columns: Int) {
        if columns >= 120 {
            self = .wide
        } else if columns >= 90 {
            self = .medium
        } else {
            self = .narrow
        }
    }
}

enum TUICompatibilityCheck: String, CaseIterable, Sendable {
    case sdkAnalysis = "SDK analysis"
    case buildComparison = "SDK and build comparison"
}

enum TUIResultsView: String, CaseIterable, Sendable {
    case findings = "Findings"
    case coverage = "Coverage"
    case failures = "Analysis issues"
}

enum TUISettingsSection: String, CaseIterable, Sendable {
    case general = "General"
    case appearance = "Appearance"
    case privacy = "Privacy"
    case cache = "Cache"
    case about = "About"
}

enum TUIDetailPresentation: Equatable, Sendable {
    case none
    case finding
    case repair
}

enum FindingGrouping: String, CaseIterable, Sendable {
    case severity
    case sourceFile
    case module
    case category
    case evidence
    case repairability
}

enum FindingSort: String, CaseIterable, Sendable {
    case severity
    case source
    case title
    case module
}

enum TUIRepairFilter: String, CaseIterable, Sendable {
    case actionable = "Actionable"
    case ready = "Ready"
    case validating = "Validating"
    case review = "Review"
    case failed = "Failed"
    case noFix = "No Fix"
    case all = "All"
}

enum TUIRepairLifecycle: String, Sendable {
    case planning = "Planning"
    case validating = "Validating"
    case ready = "Ready"
    case needsReview = "Needs Review"
    case noSafeFix = "No Safe Fix"
    case failed = "Failed"
    case stale = "Stale"
}

struct TUIRepairFunnel: Sendable {
    let findings: Int
    let actionable: Int
    let proposed: Int
    let validated: Int
    let ready: Int
    let selected: Int
}

struct TUIRepairDispositionGroup: Sendable {
    let identifier: String
    let kind: RepairFindingDispositionKind
    let title: String
    let reason: String
    let dispositions: [RepairFindingDisposition]
    let isInformational: Bool

    var hasConflict: Bool {
        dispositions.contains(where: \.hasConflict)
    }
}

enum TUIOverlay: Equatable, Sendable {
    case none
    case textInput(title: String, field: TUIEditableField, value: String)
    case requiredInput(TUIRequiredInput)
    case confirmation(title: String, message: String, action: TUIConfirmation)
    case message(title: String, message: String, details: String?)
    case shortcuts
    case logs
    case setupResolution(TUISetupResolution)
    case draftEditor(TUIRepairDraftEditor)
}

enum TUIRepairDraftEditorField: Equatable, Sendable {
    case originalAnchor
    case proposedSource
}

struct TUIRepairDraftEditor: Equatable, Sendable {
    let draftIdentifier: String
    var edits: [RepairDraftEdit]
    var selectedEditIndex: Int
    var field: TUIRepairDraftEditorField
    var cursorOffset: Int
    let explanation: String
    let validationProblems: [String]

    var selectedEdit: RepairDraftEdit? {
        guard edits.indices.contains(selectedEditIndex) else { return nil }
        return edits[selectedEditIndex]
    }
}

struct TUIRequiredInput: Equatable, Sendable {
    let title: String
    let message: String
    let field: TUIEditableField
    var value: String
    var validationMessage: String?
    let pendingOperation: TUIOperationKind
}

enum TUISetupField: String, Codable, CaseIterable, Hashable, Sendable {
    case container
    case scheme
    case buildConfiguration
    case destination
    case sdk
    case baselineXcode
    case candidateXcode
}

enum TUISetupValueOrigin: String, Codable, Sendable {
    case automatic
    case saved
    case attention
}

struct TUISetupChoice: Equatable, Sendable {
    let label: String
    let detail: String
    let value: TUISetupChoiceValue
    let recommended: Bool
    let enabled: Bool

    init(
        label: String,
        detail: String,
        value: TUISetupChoiceValue,
        recommended: Bool,
        enabled: Bool = true
    ) {
        self.label = label
        self.detail = detail
        self.value = value
        self.recommended = recommended
        self.enabled = enabled
    }
}

enum TUISetupChoiceValue: Equatable, Sendable {
    case project(String)
    case workspace(String)
    case packageRoot(String)
    case scheme(String)
    case buildConfiguration(String)
    case sdk(identifier: String, destination: String)
    case baselineXcode(String)
    case candidateXcode(String)
    case manual(TUIEditableField)
}

struct TUISetupResolution: Equatable, Sendable {
    let field: TUISetupField
    let title: String
    let message: String
    let choices: [TUISetupChoice]
    let technicalDetails: String?
    var selectedIndex = 0
    var showsTechnicalDetails = false
}

struct TUIAutomaticSetupResult: Sendable {
    let workflow: TUIWorkflowSettings
    let discovery: DiscoveryResult
    let origins: [TUISetupField: TUISetupValueOrigin]
    let selectedContainer: ProjectContainer?
    let resolution: TUISetupResolution?
    let notes: [String]
}

enum TUIConfirmation: Equatable, Sendable {
    case quit
    case applyRepairs
    case clearCache
    case pruneCache
    case clearHistory
    case clearSettings
    case cancelOperation
}

enum TUIEditableField: String, Equatable, Sendable {
    case projectRoot
    case configurationPath
    case workspacePath
    case projectPath
    case scheme
    case buildConfiguration
    case destination
    case baselineXcode
    case candidateXcode
    case sdkIdentifiers
    case compilationConditions
    case excludedPaths
    case timeout
    case doctorTimeout
    case reportOutput
    case repairFiles
    case repairIdentifiers
    case findingIdentifiers
    case repairPlanInput
    case repairOutput
    case foundationModelTimeout
    case foundationModelCandidateLimit
    case cacheMaximumAge
    case cacheMaximumSize
    case search
}

extension TUIEditableField {
    var setupField: TUISetupField? {
        switch self {
        case .workspacePath, .projectPath: .container
        case .scheme: .scheme
        case .buildConfiguration: .buildConfiguration
        case .destination: .destination
        case .baselineXcode: .baselineXcode
        case .candidateXcode: .candidateXcode
        case .sdkIdentifiers: .sdk
        default: nil
        }
    }

    var affectsAutomaticSetup: Bool {
        self == .projectRoot || self == .configurationPath || setupField != nil
    }
}

enum TUIOperationKind: String, Equatable, Hashable, Sendable {
    case automaticSetup
    case discover
    case scan
    case compare
    case doctor
    case planRepair
    case validateRepair
    case applyRepair
    case exportReport
    case exportRepairPlan
    case cacheStatus
    case cachePrune
    case cacheClear

    var title: String {
        switch self {
        case .automaticSetup: "Automatic project setup"
        case .discover: "Project discovery"
        case .scan: "SDK-derived analysis"
        case .compare: "Two-Xcode comparison"
        case .doctor: "Environment inspection"
        case .planRepair: "Repair planning"
        case .validateRepair: "Candidate repair validation"
        case .applyRepair: "Verified repair application"
        case .exportReport: "Report export"
        case .exportRepairPlan: "Repair-plan export"
        case .cacheStatus: "Cache inspection"
        case .cachePrune: "Cache pruning"
        case .cacheClear: "Cache clearing"
        }
    }
}

enum TUIOperationStatus: Equatable, Sendable {
    case idle
    case running(TUIOperationKind, startedAt: Date)
    case succeeded(TUIOperationKind, message: String)
    case cancelled(TUIOperationKind)
    case failed(TUIOperationKind, summary: String, details: String)
}

struct TUIDoctorResult: Sendable {
    let lines: [String]
    let issues: [String]
    let notes: [String]

    init(lines: [String], issues: [String], notes: [String] = []) {
        self.lines = lines
        self.issues = issues
        self.notes = notes
    }
}

struct TUIState: Sendable {
    var settings: TUISettings
    var history: TUIHistory
    var safeMode: Bool
    var screen = TUIScreen.project
    var focus = TUIFocus.content
    var navigationIndex = 0
    var contentIndex = 0
    var detailScroll = 0
    var horizontalScroll = 0
    var overlay = TUIOverlay.none
    var search = ""
    var grouping = FindingGrouping.severity
    var sorting = FindingSort.severity
    var repairFilter = TUIRepairFilter.actionable
    var activeRepairCandidateIdentifier: String?
    var severityFilter: Severity?
    var compatibilityCheck = TUICompatibilityCheck.sdkAnalysis
    var resultsView = TUIResultsView.findings
    var settingsSection = TUISettingsSection.general
    var advancedOptionsExpanded = false
    var detailPresentation = TUIDetailPresentation.none
    var selectedRepairIDs = Set<String>()
    var report: AnalysisReport?
    var repairPlan: RepairPlan?
    var repairFindingDispositions: [RepairFindingDisposition] = []
    var repairCandidates: [RepairCandidatePresentation] = []
    var repairDrafts: [RepairDraft] = []
    var repairCoverage: RepairCoverageSummary?
    var foundationModelPlanningSummary: FoundationModelPlanningSummary?
    var validatedRepairCandidateIDs = Set<String>()
    var validatedRepairIDs = Set<String>()
    var validatedCandidateRepairIdentifiers: [String: Set<String>] = [:]
    var repairValidationMessages: [String: String] = [:]
    var repairValidationSuccessMessages: [String: String] = [:]
    var repairValidationSkippedMessages: [String: String] = [:]
    var staleRepairCandidateIDs = Set<String>()
    var validatingRepairCandidateID: String?
    var discovery: DiscoveryResult?
    var selectedContainer: ProjectContainer?
    var setupOrigins: [TUISetupField: TUISetupValueOrigin] = [:]
    var setupNotes: [String] = []
    var requestedSetupField: TUISetupField?
    var pendingOperation: TUIOperationKind?
    var doctorResult: TUIDoctorResult?
    var projectWasExplicitlySelected = false
    var advanceAfterSetup = false
    var cacheStatus: SDKCacheStatus?
    var operationStatus = TUIOperationStatus.idle
    var operationPaused = false
    var progressLines: [String] = []
    var progressMeasurement: OperationProgressMeasurement?
    var technicalLog: [String] = []
    var lastExportPath: String?
    var settingsWarning: String?
    var foundationModelStatus = OnDeviceFoundationModelStatus.unavailable
    var shouldQuit = false

    init(
        settings: TUISettings,
        history: TUIHistory,
        safeMode: Bool,
        settingsWarning: String? = nil,
        foundationModelStatus: OnDeviceFoundationModelStatus = .unavailable
    ) {
        self.settings = settings
        self.history = history
        self.safeMode = safeMode
        self.settingsWarning = settingsWarning
        self.foundationModelStatus = foundationModelStatus
        self.setupOrigins = (settings.workflow.setupValueOrigins ?? [:])
            .reduce(into: [:]) {
                guard let field = TUISetupField(rawValue: $1.key) else {
                    return
                }
                $0[field] = $1.value
            }
    }

    var findings: [Finding] {
        guard let report else { return [] }
        return report.findings.filter { finding in
            let severityMatches = severityFilter == nil
                || finding.severity == severityFilter
            guard severityMatches else { return false }
            guard !search.isEmpty else { return true }
            let needle = search.lowercased()
            return [
                finding.title,
                finding.explanation,
                finding.findingID,
                finding.location?.path,
                finding.sdkEvidence?.moduleName,
            ].compactMap { $0 }.contains {
                $0.lowercased().contains(needle)
            }
        }.sorted(by: findingOrder)
    }

    var navigationScreens: [TUIScreen] {
        var values: [TUIScreen] = [.project, .check]
        if doctorPassed || report != nil {
            values.append(.findings)
        }
        if report != nil || repairPlan != nil {
            values.append(.repair)
        }
        return values
    }

    var selectedFinding: Finding? {
        let values = findings
        guard !values.isEmpty else { return nil }
        let index = max(
            0,
            contentIndex - TUIContentRows.resultControlCount(for: self)
        )
        return values[min(index, values.count - 1)]
    }

    var selectedRepair: ProposedRepair? {
        guard let candidate = selectedRepairCandidate,
              let repairID = effectiveRepairIdentifiers(
                for: candidate
              ).first,
              let repair = repairPlan?.repairs.first(where: {
                  $0.repairIdentifier == repairID
              })
        else {
            return nil
        }
        return repair
    }

    var selectedRepairCandidate: RepairCandidatePresentation? {
        let candidates = displayedRepairCandidates
        guard !candidates.isEmpty else { return nil }
        let index = contentIndex - TUIContentRows.rows(for: self).count
        if candidates.indices.contains(index) {
            return candidates[index]
        }
        return activeRepairCandidate
    }

    var activeRepairCandidate: RepairCandidatePresentation? {
        guard let activeRepairCandidateIdentifier else { return nil }
        return allRepairCandidates.first {
            $0.candidateIdentifier == activeRepairCandidateIdentifier
        }
    }

    var allRepairCandidates: [RepairCandidatePresentation] {
        if !repairCandidates.isEmpty {
            return repairCandidates.map { candidate in
                guard let draftIdentifier = candidate.draftIdentifier,
                      let draft = repairDrafts.first(where: {
                          $0.draftIdentifier == draftIdentifier
                      })
                else {
                    return candidate
                }
                return RepairCandidatePresentation(
                    candidateIdentifier: candidate.candidateIdentifier,
                    draftIdentifier: draftIdentifier,
                    findingStableKey: candidate.findingStableKey,
                    findingIdentifier: candidate.findingIdentifier,
                    title: candidate.title,
                    location: candidate.location,
                    symbol: candidate.symbol,
                    status: candidate.status,
                    repairSource: candidate.repairSource,
                    confidence: candidate.confidence,
                    summary: draft.edits.count == 1
                        ? "\(draft.edits[0].operation.rawValue) draft"
                        : "\(draft.edits.count) coordinated edit draft",
                    explanation: draft.explanation,
                    evidence: draft.evidence,
                    risks: draft.assumptions
                        + draft.risks
                        + draft.initialIssues.map {
                            "\($0.stage.rawValue): \($0.message)"
                        },
                    repairIdentifiers: effectiveRepairIdentifiers(
                        for: candidate
                    ),
                    edits: draft.edits.map {
                        RepairCandidateEditPresentation(
                            operation: $0.operation.rawValue,
                            filePath: $0.sourceFileIdentity,
                            originalText: $0.originalAnchor,
                            replacementText: $0.proposedSource
                        )
                    },
                    verificationMessage:
                        repairValidationSuccessMessages[
                            candidate.candidateIdentifier
                        ]
                        ?? candidate.verificationMessage
                )
            }
        }
        guard let repairPlan else { return [] }
        return RepairCandidatePresentationBuilder.build(
            findings: report?.findings ?? [],
            plan: repairPlan,
            dispositions: repairFindingDispositions
        )
    }

    var displayedRepairCandidates: [RepairCandidatePresentation] {
        allRepairCandidates.filter { candidate in
            let lifecycle = repairLifecycle(for: candidate)
            switch repairFilter {
            case .actionable:
                return !candidate.edits.isEmpty
                    && lifecycle != .noSafeFix
            case .ready:
                return lifecycle == .ready
            case .validating:
                return lifecycle == .planning
                    || lifecycle == .validating
            case .review:
                return lifecycle == .needsReview
            case .failed:
                return lifecycle == .failed || lifecycle == .stale
            case .noFix:
                return lifecycle == .noSafeFix
            case .all:
                return true
            }
        }
    }

    func effectiveStatus(
        for candidate: RepairCandidatePresentation
    ) -> RepairCandidateStatus {
        if validatedRepairCandidateIDs.contains(candidate.candidateIdentifier) {
            return .ready
        }
        if repairValidationMessages[candidate.candidateIdentifier] != nil {
            return .verificationFailed
        }
        return candidate.status
    }

    func candidateIsSelectable(
        _ candidate: RepairCandidatePresentation
    ) -> Bool {
        repairLifecycle(for: candidate) == .ready
            && !effectiveRepairIdentifiers(for: candidate).isEmpty
            && Set(effectiveRepairIdentifiers(for: candidate))
                .isDisjoint(with: repairConflictIdentifiers)
    }

    func candidateNeedsSemanticReview(
        _ candidate: RepairCandidatePresentation
    ) -> Bool {
        let identifiers = Set(effectiveRepairIdentifiers(for: candidate))
        let repairs = repairPlan?.repairs.filter {
            identifiers.contains($0.repairIdentifier)
        } ?? []
        return candidate.repairSource == "Apple Foundation Models"
            || repairs.contains {
                $0.requiresReview == true
                    || $0.modelGenerated == true
                    || $0.safety != .safe
            }
    }

    func repairLifecycle(
        for candidate: RepairCandidatePresentation
    ) -> TUIRepairLifecycle {
        if staleRepairCandidateIDs.contains(candidate.candidateIdentifier) {
            return .stale
        }
        if validatingRepairCandidateID == candidate.candidateIdentifier {
            return .validating
        }
        if !Set(effectiveRepairIdentifiers(for: candidate))
            .isDisjoint(with: repairConflictIdentifiers)
        {
            return .failed
        }
        if validatedRepairCandidateIDs.contains(candidate.candidateIdentifier) {
            return .ready
        }
        if repairValidationMessages[candidate.candidateIdentifier] != nil {
            return .failed
        }
        switch candidate.status {
        case .ready:
            return .ready
        case .needsValidation, .reviewRequired:
            return .needsReview
        case .verificationFailed, .rejected:
            return .failed
        case .noProposal:
            return .noSafeFix
        }
    }

    var repairConflictIdentifiers: Set<String> {
        Set(repairPlan?.conflicts.flatMap(\.repairIdentifiers) ?? [])
    }

    var repairFunnel: TUIRepairFunnel {
        let candidates = allRepairCandidates
        let actionable = candidates.filter {
            !$0.edits.isEmpty && repairLifecycle(for: $0) != .noSafeFix
        }
        let validated = candidates.count {
            validatedRepairCandidateIDs.contains($0.candidateIdentifier)
                || repairValidationMessages[$0.candidateIdentifier] != nil
        }
        let selectedCandidates = candidates.count { candidate in
            let identifiers = Set(effectiveRepairIdentifiers(for: candidate))
            return !identifiers.isEmpty
                && identifiers.isSubset(of: selectedRepairIDs)
        }
        return TUIRepairFunnel(
            findings: repairCoverage?.findingsReceived
                ?? repairFindingDispositions.count,
            actionable: actionable.count,
            proposed: candidates.count { !$0.edits.isEmpty },
            validated: validated,
            ready: candidates.count {
                repairLifecycle(for: $0) == .ready
            },
            selected: selectedCandidates
        )
    }

    func effectiveRepairIdentifiers(
        for candidate: RepairCandidatePresentation
    ) -> [String] {
        if let promoted = validatedCandidateRepairIdentifiers[
            candidate.candidateIdentifier
        ] {
            return promoted.sorted()
        }
        return candidate.repairIdentifiers
    }

    func draft(
        for candidate: RepairCandidatePresentation
    ) -> RepairDraft? {
        guard let identifier = candidate.draftIdentifier else { return nil }
        return repairDrafts.first {
            $0.draftIdentifier == identifier
        }
    }

    var repairDispositionGroups: [TUIRepairDispositionGroup] {
        let grouped = Dictionary(
            grouping: repairFindingDispositions
        ) {
            [
                $0.kind.rawValue,
                $0.title,
                $0.reason,
                $0.hasConflict ? "conflict" : "clear",
            ].joined(separator: "\u{1F}")
        }
        return grouped.map { identifier, dispositions in
            let sorted = dispositions.sorted {
                $0.findingStableKey < $1.findingStableKey
            }
            let representative = sorted[0]
            return TUIRepairDispositionGroup(
                identifier: identifier,
                kind: representative.kind,
                title: representative.title,
                reason: representative.reason,
                dispositions: sorted,
                isInformational: sorted.allSatisfy { disposition in
                    guard let finding = report?.findings.first(
                        where: {
                            $0.stableKey
                                == disposition.findingStableKey
                        }
                    ) else {
                        return false
                    }
                    return finding.severity == .notice
                        || finding.location == nil
                }
            )
        }.sorted {
            if $0.kind.rawValue != $1.kind.rawValue {
                return $0.kind.rawValue < $1.kind.rawValue
            }
            return $0.title < $1.title
        }
    }

    var analysisIsComplete: Bool {
        guard let report else { return false }
        return report.analysisState == .completeAndClean
            || report.analysisState == .completeWithFindings
    }

    var missingSetupRequirements: [String] {
        let workflow = settings.workflow
        var missing: [String] = []
        if !projectWasExplicitlySelected {
            missing.append("project")
        }
        if selectedContainer == nil {
            missing.append("container")
        } else if selectedContainer?.kind != .package,
                  workflow.scheme?.isEmpty != false
        {
            missing.append("scheme")
        }
        if workflow.buildConfiguration?.isEmpty != false {
            missing.append("configuration")
        }
        if workflow.baselineXcodePath?.isEmpty != false
            || setupOrigins[.baselineXcode] != .saved
        {
            missing.append("baseline Xcode")
        }
        if workflow.candidateXcodePath?.isEmpty != false
            || setupOrigins[.candidateXcode] != .saved
        {
            missing.append("candidate Xcode")
        }
        if workflow.sdkIdentifiers.isEmpty
            || workflow.destination?.isEmpty != false
            || setupOrigins[.sdk] != .saved
            || setupOrigins[.destination] != .saved
        {
            missing.append("platform")
        }
        return missing
    }

    var setupIsReady: Bool {
        missingSetupRequirements.isEmpty
    }

    var doctorPassed: Bool {
        setupIsReady && doctorResult?.issues.isEmpty == true
    }

    var projectDisplayName: String {
        guard projectWasExplicitlySelected else {
            return "SwiftDelta"
        }
        let sourceURL: URL
        if let selectedContainer {
            let containerURL = URL(fileURLWithPath: selectedContainer.path)
            sourceURL = selectedContainer.kind == .package
                ? containerURL.deletingLastPathComponent()
                : containerURL.deletingPathExtension()
        } else {
            sourceURL = URL(fileURLWithPath: settings.workflow.projectRoot)
        }
        let name = sourceURL.lastPathComponent
        return name.isEmpty ? "Selected Project" : name
    }

    func findingGroups() -> [(name: String, count: Int)] {
        Dictionary(grouping: findings, by: groupKey)
            .map { key, values in
                (
                    key.replacingOccurrences(
                        of: #"^\d-"#,
                        with: "",
                        options: .regularExpression
                    ),
                    values.count
                )
            }
            .sorted { $0.name < $1.name }
    }

    private func findingOrder(_ left: Finding, _ right: Finding) -> Bool {
        let leftGroup = groupKey(for: left)
        let rightGroup = groupKey(for: right)
        if leftGroup != rightGroup {
            return leftGroup < rightGroup
        }
        switch sorting {
        case .severity:
            if left.severity.rank != right.severity.rank {
                return left.severity.rank > right.severity.rank
            }
        case .source:
            let lhs = left.location?.path ?? ""
            let rhs = right.location?.path ?? ""
            if lhs != rhs { return lhs < rhs }
        case .title:
            if left.title != right.title { return left.title < right.title }
        case .module:
            let lhs = left.sdkEvidence?.moduleName ?? ""
            let rhs = right.sdkEvidence?.moduleName ?? ""
            if lhs != rhs { return lhs < rhs }
        }
        return left.findingID < right.findingID
    }

    func groupKey(for finding: Finding) -> String {
        switch grouping {
        case .severity:
            return "\(4 - finding.severity.rank)-\(finding.severity.rawValue)"
        case .sourceFile:
            return finding.location?.path ?? "No source location"
        case .module:
            return finding.sdkEvidence?.moduleName ?? "No SDK module"
        case .category:
            return finding.category.rawValue
        case .evidence:
            return finding.origin.rawValue
        case .repairability:
            return finding.automaticRemediationSupported
                ? "Repair available" : "No automatic repair"
        }
    }
}
