//===--- TUIOperationService.swift - SwiftDelta ------------------------------------------===//
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

struct TUIOperationRequest: Sendable {
    let settings: TUISettings
    let report: AnalysisReport?
    let repairPlan: RepairPlan?
    let selectedRepairIdentifiers: Set<String>
    let validatedRepairIdentifiers: Set<String>
    let repairCandidateIdentifier: String?
    let repairDraft: RepairDraft?
    let requestedSetupField: TUISetupField?
    let foundationModelStatus: OnDeviceFoundationModelStatus

    init(
        settings: TUISettings,
        report: AnalysisReport?,
        repairPlan: RepairPlan?,
        selectedRepairIdentifiers: Set<String>,
        validatedRepairIdentifiers: Set<String> = [],
        repairCandidateIdentifier: String? = nil,
        repairDraft: RepairDraft? = nil,
        requestedSetupField: TUISetupField? = nil,
        foundationModelStatus: OnDeviceFoundationModelStatus = .unavailable
    ) {
        self.settings = settings
        self.report = report
        self.repairPlan = repairPlan
        self.selectedRepairIdentifiers = selectedRepairIdentifiers
        self.validatedRepairIdentifiers = validatedRepairIdentifiers
        self.repairCandidateIdentifier = repairCandidateIdentifier
        self.repairDraft = repairDraft
        self.requestedSetupField = requestedSetupField
        self.foundationModelStatus = foundationModelStatus
    }
}

enum TUIOperationResult: Sendable {
    case automaticSetup(TUIAutomaticSetupResult)
    case discovery(DiscoveryResult)
    case report(AnalysisReport)
    case doctor(TUIDoctorResult)
    case repairPlan(RepairPlanningOutput)
    case preparedRepairPlan(TUIPreparedRepairPlan)
    case repairValidated(
        candidateIdentifier: String,
        repairs: [ProposedRepair],
        message: String
    )
    case repairsApplied(Int)
    case reportExported(String)
    case repairPlanExported(String)
    case cacheStatus(SDKCacheStatus)
    case cacheChanged(String, SDKCacheStatus)
}

/// Runtime-only result of preview generation and isolated validation.
///
/// The versioned repair-plan schema remains unchanged: automatic validation
/// records describe the current TUI session and never become source evidence
/// on their own.
struct TUIPreparedRepairPlan: Sendable {
    let output: RepairPlanningOutput
    let validatedCandidateIdentifiers: Set<String>
    let repairIdentifiersByCandidate: [String: Set<String>]
    let successMessages: [String: String]
    let failureMessages: [String: String]
    let skippedMessages: [String: String]
}

enum TUIOperationProgressUpdate: Sendable {
    case message(String)
    case measurement(OperationProgressMeasurement?)
}

protocol TUIOperationServing: Sendable {
    func perform(
        _ kind: TUIOperationKind,
        request: TUIOperationRequest,
        cancellation: @escaping @Sendable () -> Bool,
        pauseRequested: @escaping @Sendable () -> Bool,
        progress: @escaping @Sendable (TUIOperationProgressUpdate) -> Void
    ) throws -> TUIOperationResult
}

extension TUIOperationServing {
    func perform(
        _ kind: TUIOperationKind,
        request: TUIOperationRequest,
        cancellation: @escaping @Sendable () -> Bool,
        progress: @escaping @Sendable (TUIOperationProgressUpdate) -> Void
    ) throws -> TUIOperationResult {
        try perform(
            kind,
            request: request,
            cancellation: cancellation,
            pauseRequested: { false },
            progress: progress
        )
    }
}

struct CoreTUIOperationService: TUIOperationServing {
    func perform(
        _ kind: TUIOperationKind,
        request: TUIOperationRequest,
        cancellation: @escaping @Sendable () -> Bool,
        pauseRequested: @escaping @Sendable () -> Bool,
        progress progressSink:
            @escaping @Sendable (TUIOperationProgressUpdate) -> Void
    ) throws -> TUIOperationResult {
        let workflow = request.settings.workflow
        try validate(
            workflow,
            foundationModelStatus: request.foundationModelStatus
        )
        let root = canonicalRoot(workflow.projectRoot)
        let operationProgress = OperationProgress(
            quiet: workflow.progressQuiet,
            measurementSink: {
                progressSink(.measurement($0))
            },
            sink: {
                progressSink(.message($0))
            }
        )
        let runner = CancellableProcessRunner(cancellation: cancellation)
        let pausableRepairCancellation: @Sendable () -> Bool = {
            while pauseRequested(), !cancellation() {
                Thread.sleep(forTimeInterval: 0.05)
            }
            return cancellation()
        }
        switch kind {
        case .automaticSetup:
            return .automaticSetup(
                try automaticSetup(
                    root: root,
                    workflow: workflow,
                    runner: runner,
                    progress: operationProgress,
                    cancellation: cancellation,
                    requestedField: request.requestedSetupField
                )
            )
        case .discover:
            return .discovery(
                try ProjectDiscovery().discover(
                    root: root,
                    excludedPaths: workflow.excludedPaths
                )
            )
        case .scan:
            return .report(
                try scan(
                    root: root,
                    workflow: workflow,
                    runner: runner,
                    progress: operationProgress
                )
            )
        case .compare:
            return .report(
                try compare(
                    root: root,
                    workflow: workflow,
                    runner: runner,
                    progress: operationProgress,
                    cancellation: cancellation
                )
            )
        case .doctor:
            return .doctor(
                try doctor(
                    root: root,
                    workflow: workflow,
                    runner: runner,
                    progress: operationProgress,
                    cancellation: cancellation
                )
            )
        case .planRepair:
            let output: RepairPlanningOutput
            if let path = workflow.repairPlanInputPath {
                let url = resolvePath(path, relativeTo: root)
                let plan = try RepairPlanJSON.decode(
                    Data(contentsOf: url, options: [.mappedIfSafe])
                )
                try RepairPlanPreflight.validate(plan, projectRoot: root)
                let coverage = RepairFindingDispositionBuilder.build(
                    findings: request.report?.findings ?? [],
                    plan: plan,
                    projectRoot: root,
                    modelAssistanceRequested:
                        request.foundationModelStatus.isAvailable
                )
                output = RepairPlanningOutput(
                    plan: plan,
                    referenceResolutionCoverage:
                        request.report?.referenceResolutionCoverage ?? [],
                    findingDispositions: coverage.dispositions,
                    repairCoverage: coverage.summary
                )
            } else {
                let configuration = try effectiveConfiguration(
                    root: root,
                    workflow: workflow,
                    forRepair: true
                )
                output = try RepairPlanningEngine(
                    runner: runner,
                    progress: operationProgress
                ).planWithEvidence(
                    RepairPlanningRequest(
                        root: root,
                        configuration: configuration,
                        selectedSourcePaths: workflow.repairSourcePaths,
                        selectedFindingIdentifiers:
                            Set(workflow.findingIdentifiers),
                        timeoutPerFile: workflow.timeout,
                        sdkCachePolicy: workflow.sdkCachePolicy,
                        buildConfiguration: workflow.buildConfiguration,
                        destination: workflow.destination,
                        foundationModelOptions: foundationModelOptions(
                            workflow,
                            status: request.foundationModelStatus
                        ),
                        analysisReport: request.report
                    ),
                    cancellation: pausableRepairCancellation
                )
            }
            return .preparedRepairPlan(
                automaticallyValidateRepairCandidates(
                    output,
                    root: root,
                    workflow: workflow,
                    runner: runner,
                    progress: operationProgress,
                    cancellation: pausableRepairCancellation,
                    pauseRequested: pauseRequested
                )
            )
        case .validateRepair:
            guard let candidateIdentifier = request.repairCandidateIdentifier
            else {
                throw SwiftDeltaError.missingSelection("repair candidate")
            }
            return try validateRepairCandidate(
                plan: request.repairPlan,
                identifiers: request.selectedRepairIdentifiers,
                draft: request.repairDraft,
                candidateIdentifier: candidateIdentifier,
                root: root,
                workflow: workflow,
                runner: runner,
                progress: operationProgress
            )
        case .applyRepair:
            guard let plan = request.repairPlan else {
                throw SwiftDeltaError.missingSelection("repair plan")
            }
            return try applyRepairs(
                plan: plan,
                identifiers: request.selectedRepairIdentifiers,
                validatedIdentifiers: request.validatedRepairIdentifiers,
                root: root,
                workflow: workflow,
                runner: runner,
                progress: operationProgress
            )
        case .exportReport:
            guard let report = request.report else {
                throw SwiftDeltaError.missingSelection("analysis report")
            }
            guard let path = workflow.reportOutputPath, !path.isEmpty else {
                throw SwiftDeltaError.missingSelection("report output path")
            }
            let data = try ReportRenderer.render(
                report,
                format: workflow.reportFormat,
                failureLevel: workflow.failureLevel
            )
            let output = resolvePath(path, relativeTo: root)
            try ReportRenderer.write(data, to: output)
            return .reportExported(output.path)
        case .exportRepairPlan:
            guard let plan = request.repairPlan else {
                throw SwiftDeltaError.missingSelection("repair plan")
            }
            guard let path = workflow.repairOutputPath, !path.isEmpty else {
                throw SwiftDeltaError.missingSelection(
                    "repair-plan output path"
                )
            }
            let data = try RepairPlanRenderer.render(
                plan,
                format: workflow.repairPlanFormat
            )
            let output = resolvePath(path, relativeTo: root)
            try RepairPlanRenderer.write(data, to: output)
            return .repairPlanExported(output.path)
        case .cacheStatus:
            return .cacheStatus(try SDKCacheManager().status())
        case .cachePrune:
            let result = try SDKCacheManager().prune(
                maximumAge: request.settings.cache.maximumAgeDays.map {
                    $0 * 86_400
                },
                maximumSize: request.settings.cache.maximumSizeMiB.map {
                    Int64($0 * 1_024 * 1_024)
                }
            )
            return .cacheChanged(
                "Removed \(result.removedEntries) cache entries "
                    + "(\(result.removedBytes) bytes).",
                try SDKCacheManager().status()
            )
        case .cacheClear:
            let result = try SDKCacheManager().clear()
            return .cacheChanged(
                "Removed \(result.removedEntries) cache entries "
                    + "(\(result.removedBytes) bytes).",
                try SDKCacheManager().status()
            )
        }
    }
}
