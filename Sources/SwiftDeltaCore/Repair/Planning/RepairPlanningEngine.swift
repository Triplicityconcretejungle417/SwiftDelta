//===--- RepairPlanningEngine.swift - SwiftDelta ------------------------------------------===//
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

public struct RepairPlanningRequest: Sendable {
    public let root: URL
    public let configuration: SwiftDeltaConfiguration
    public let selectedSourcePaths: [String]
    public let selectedFindingIdentifiers: Set<String>
    public let timeoutPerFile: TimeInterval
    public let sdkCachePolicy: SDKSnapshotCachePolicy
    public let sdkCacheDirectory: URL?
    public let buildConfiguration: String?
    public let destination: String?
    public let foundationModelOptions: FoundationModelRepairOptions?
    public let analysisReport: AnalysisReport?

    public init(
        root: URL,
        configuration: SwiftDeltaConfiguration,
        selectedSourcePaths: [String] = [],
        selectedFindingIdentifiers: Set<String> = [],
        timeoutPerFile: TimeInterval = 60,
        sdkCachePolicy: SDKSnapshotCachePolicy = .use,
        sdkCacheDirectory: URL? = nil,
        buildConfiguration: String? = nil,
        destination: String? = nil,
        foundationModelOptions: FoundationModelRepairOptions? = nil,
        analysisReport: AnalysisReport? = nil
    ) {
        self.root = root
        self.configuration = configuration
        self.selectedSourcePaths = selectedSourcePaths
        self.selectedFindingIdentifiers = selectedFindingIdentifiers
        self.timeoutPerFile = timeoutPerFile
        self.sdkCachePolicy = sdkCachePolicy
        self.sdkCacheDirectory = sdkCacheDirectory
        self.buildConfiguration = buildConfiguration
        self.destination = destination
        self.foundationModelOptions = foundationModelOptions
        self.analysisReport = analysisReport
    }
}

public struct RepairPlanningEngine: Sendable {
    private let runner: any ProcessRunning
    private let progress: OperationProgress
    private let foundationModelProvider: (any FoundationModelRepairProviding)?

    public init(
        runner: any ProcessRunning = ProcessRunner(),
        progress: OperationProgress = .silent
    ) {
        self.runner = runner
        self.progress = progress
        foundationModelProvider = nil
    }

    init(
        runner: any ProcessRunning = ProcessRunner(),
        progress: OperationProgress = .silent,
        foundationModelProvider: any FoundationModelRepairProviding
    ) {
        self.runner = runner
        self.progress = progress
        self.foundationModelProvider = foundationModelProvider
    }

    public func plan(
        _ request: RepairPlanningRequest,
        generatedAt: Date = Date(),
        cancellation: @escaping @Sendable () -> Bool = { false }
    ) throws -> RepairPlan {
        try planWithEvidence(
            request,
            generatedAt: generatedAt,
            cancellation: cancellation
        ).plan
    }

    public func planWithEvidence(
        _ request: RepairPlanningRequest,
        generatedAt: Date = Date(),
        cancellation: @escaping @Sendable () -> Bool = { false }
    ) throws -> RepairPlanningOutput {
        try request.configuration.validate(requireXcodePair: true)
        guard let candidateXcode = request.configuration.candidateXcodePath else {
            throw SwiftDeltaError.missingSelection("candidate Xcode application")
        }
        let root = request.root.standardizedFileURL.resolvingSymlinksInPath()
        if let report = request.analysisReport {
            let reportRoot = URL(
                fileURLWithPath: report.projectRoot,
                isDirectory: true
            ).standardizedFileURL.resolvingSymlinksInPath()
            guard reportRoot.path == root.path else {
                throw RepairError.invalidPlan(
                    "the Analysis result belongs to a different project root"
                )
            }
        }
        let discovery = try progress.phase(
            "Discovering project for repair",
            completedMessage: "Discovered project for repair"
        ) {
            try ProjectDiscovery().discover(
                root: root,
                excludedPaths: request.configuration.excludedPaths
            )
        }
        var configuration = request.configuration
        if configuration.sdkIdentifiers.isEmpty {
            configuration.sdkIdentifiers = ["macosx"]
        }
        let sourceFiles = try progress.phase(
            "Selecting repair source files",
            completedMessage: "Selected \(request.selectedSourcePaths.isEmpty ? "project" : "requested") repair source files"
        ) {
            try RepairSourceDiscovery().discover(
                root: root,
                excludedPaths: configuration.excludedPaths,
                selectedPaths: request.selectedSourcePaths
            )
        }
        let selectedSwiftFiles = sourceFiles
            .filter { $0.pathExtension.lowercased() == "swift" }
            .map { $0.standardizedFileURL.path }
        let sdkDiscovery = request.selectedSourcePaths.isEmpty
            ? discovery
            : DiscoveryResult(
                root: discovery.root,
                containers: discovery.containers,
                swiftFiles: selectedSwiftFiles
            )
        if !request.selectedSourcePaths.isEmpty {
            progress.message(
                "Scoped repair analysis to \(sourceFiles.count) selected source file(s)"
            )
        }
        let sdkOutput = try progress.phase(
            "Collecting SDK repair evidence",
            completedMessage: "Collected SDK repair evidence"
        ) {
            if sdkDiscovery.swiftFiles.isEmpty {
                return SDKAnalysisOutput(
                    findings: [],
                    failures: [],
                    baselineSnapshots: [],
                    candidateSnapshots: [],
                    references: [],
                    referenceResolutionCoverage: []
                )
            }
            return try SDKAnalysisEngine(runner: runner, progress: progress).analyze(
                discovery: sdkDiscovery,
                configuration: configuration,
                timeoutPerOperation: request.timeoutPerFile,
                sdkCachePolicy: request.sdkCachePolicy,
                sdkCacheDirectory: request.sdkCacheDirectory,
                buildConfiguration: request.buildConfiguration,
                destination: request.destination,
                cancellation: cancellation
            )
        }
        let sdkIdentifier = configuration.sdkIdentifiers.first ?? "macosx"
        let candidateIdentity: SDKInstallationIdentity
        if let resolvedIdentity = sdkOutput.candidateIdentities.first(
            where: { $0.sdkIdentifier == sdkIdentifier }
        ) {
            candidateIdentity = resolvedIdentity
        } else if let extractedIdentity = sdkOutput.candidateSnapshots.first(
            where: { $0.identity.sdkIdentifier == sdkIdentifier }
        )?.identity {
            candidateIdentity = extractedIdentity
        } else {
            candidateIdentity = try SDKSnapshotExtractor(runner: runner).inspectIdentity(
                xcodeApplicationPath: candidateXcode,
                sdkIdentifier: sdkIdentifier,
                timeout: min(request.timeoutPerFile, 120)
            )
        }
        let compilerOutput = try progress.phase(
            "Collecting compiler fix-it evidence",
            completedMessage: "Collected compiler fix-it evidence"
        ) {
            try CompilerFixItExtractor(runner: runner).extract(
                CompilerFixItRequest(
                    files: sourceFiles,
                    projectRoot: root,
                    candidateXcodePath: candidateXcode,
                    sdkIdentifier: sdkIdentifier,
                    activeCompilationConditions: configuration.activeCompilationConditions,
                    timeoutPerFile: request.timeoutPerFile,
                    targetBuildContexts: sdkOutput.candidateBuildContexts
                ),
                cancellation: cancellation
            )
        }
        let repairFindings = request.analysisReport?.findings
            ?? sdkOutput.findings
        let compilerRepairs = CompilerFixItRepairBuilder.build(
            fixIts: compilerOutput.fixIts,
            projectRoot: root,
            candidateIdentity: candidateIdentity,
            analysisFindings: repairFindings
        )
        let sdkRepairs = SDKRepairEvidenceBuilder.build(
            findings: repairFindings,
            baselineSnapshots: sdkOutput.baselineSnapshots,
            candidateSnapshots: sdkOutput.candidateSnapshots,
            projectRoot: root,
            targetBuildContexts: sdkOutput.candidateBuildContexts
        )
        let inheritedFailures = request.analysisReport?.failures ?? []
        let deterministicPlan = progress.phase(
            "Generating repair plan",
            completedMessage: "Generated repair plan"
        ) {
            RepairPlanBuilder.build(
                projectRoot: root,
                repairs: compilerRepairs.0 + sdkRepairs.0,
                planningFailures: uniqueRepairPlanningFailures(
                    sdkOutput.failures
                        + inheritedFailures
                        + compilerOutput.failures
                        + compilerRepairs.1
                        + sdkRepairs.1
                ),
                generatedAt: generatedAt
            )
        }
        let plan: RepairPlan
        let foundationModelSummary: FoundationModelPlanningSummary?
        var modelNotRepairableReasons: [String: String] = [:]
        var modelSkippedReasons: [String: String] = [:]
        var modelRepairFindingStableKeys: [String: String] = [:]
        var modelCandidateAttempts: [RepairCandidatePresentation] = []
        var modelDrafts: [RepairDraft] = []
        if let options = request.foundationModelOptions {
            let contextResult = progress.phase(
                "Preparing Foundation Models repair context",
                completedMessage:
                    "Prepared Foundation Models repair context"
            ) {
                FoundationModelRepairContextBuilder.buildWithFailures(
                    sdkOutput: sdkOutput,
                    findings: repairFindings,
                    deterministicRepairs: deterministicPlan.repairs,
                    compilerFixIts: compilerOutput.fixIts,
                    projectRoot: root,
                    selectedFindingIdentifiers:
                        request.selectedFindingIdentifiers
                )
            }
            let assisted = FoundationModelRepairPlanner(
                provider: foundationModelProvider
                    ?? AppleFoundationModelRepairProvider(),
                progress: progress
            ).proposeRepairs(
                contexts: contextResult.contexts,
                options: options,
                projectRoot: root,
                findingsConsidered: contextResult.findingsConsidered,
                initiallySkipped: contextResult.skipped,
                cancellation: cancellation
            )
            foundationModelSummary = assisted.summary
            modelNotRepairableReasons = assisted.notRepairableReasons
            modelSkippedReasons = contextResult.skipReasons
            modelRepairFindingStableKeys =
                assisted.repairFindingStableKeys
            modelCandidateAttempts = assisted.candidateAttempts
            modelDrafts = assisted.drafts
            plan = RepairPlanBuilder.build(
                projectRoot: root,
                repairs: deterministicPlan.repairs + assisted.0,
                planningFailures: uniqueRepairPlanningFailures(
                    deterministicPlan.planningFailures
                        + contextResult.failures
                        + assisted.1
                ),
                generatedAt: generatedAt
            )
        } else {
            plan = deterministicPlan
            foundationModelSummary = nil
        }
        let coverage = RepairFindingDispositionBuilder.build(
            findings: repairFindings,
            plan: plan,
            projectRoot: root,
            modelAssistanceRequested: request.foundationModelOptions != nil,
            modelNotRepairableReasons: modelNotRepairableReasons,
            modelSkippedReasons: modelSkippedReasons,
            modelDraftFindingStableKeys: Set(
                modelDrafts.map(\.findingStableKey)
            ),
            repairFindingStableKeys: modelRepairFindingStableKeys
        )
        let builtCandidates = RepairCandidatePresentationBuilder.build(
            findings: repairFindings,
            plan: plan,
            dispositions: coverage.dispositions,
            modelAttempts: modelCandidateAttempts
        )
        let candidates = builtCandidates.map { candidate in
            guard candidate.draftIdentifier == nil,
                  candidate.repairSource == "Apple Foundation Models",
                  let draft = modelDrafts.first(where: {
                      $0.findingStableKey == candidate.findingStableKey
                  })
            else {
                return candidate
            }
            return candidate.attachingDraftIdentifier(
                draft.draftIdentifier
            )
        }
        return RepairPlanningOutput(
            plan: plan,
            referenceResolutionCoverage:
                sdkOutput.referenceResolutionCoverage,
            offeredFindingIdentifiers: Set(
                sdkOutput.findings.map(\.findingID)
                    + compilerRepairs.0.map(\.relatedFindingIdentifier)
            ),
            offeredFindingOccurrences: Set(
                sdkOutput.findings.map(RepairFindingOccurrence.init)
            ),
            findingDispositions: coverage.dispositions,
            repairCoverage: coverage.summary,
            foundationModelSummary: foundationModelSummary,
            repairCandidates: candidates,
            repairDrafts: modelDrafts
        )
    }
}

private func uniqueRepairPlanningFailures(
    _ failures: [AnalysisFailure]
) -> [AnalysisFailure] {
    var seen = Set<AnalysisFailure>()
    return failures.filter { seen.insert($0).inserted }
}

public struct RepairPlanningOutput: Sendable {
    public let plan: RepairPlan
    public let referenceResolutionCoverage: [ReferenceResolutionCoverage]
    public let offeredFindingIdentifiers: Set<String>
    public let offeredFindingOccurrences: Set<RepairFindingOccurrence>
    public let findingDispositions: [RepairFindingDisposition]
    public let repairCoverage: RepairCoverageSummary
    public let foundationModelSummary: FoundationModelPlanningSummary?
    public let repairCandidates: [RepairCandidatePresentation]
    public let repairDrafts: [RepairDraft]

    public init(
        plan: RepairPlan,
        referenceResolutionCoverage: [ReferenceResolutionCoverage],
        offeredFindingIdentifiers: Set<String> = [],
        offeredFindingOccurrences: Set<RepairFindingOccurrence> = [],
        findingDispositions: [RepairFindingDisposition] = [],
        repairCoverage: RepairCoverageSummary? = nil,
        foundationModelSummary: FoundationModelPlanningSummary? = nil,
        repairCandidates: [RepairCandidatePresentation] = [],
        repairDrafts: [RepairDraft] = []
    ) {
        self.plan = plan
        self.referenceResolutionCoverage = referenceResolutionCoverage
        self.offeredFindingIdentifiers = offeredFindingIdentifiers
        self.offeredFindingOccurrences = offeredFindingOccurrences
        self.findingDispositions = findingDispositions
        self.foundationModelSummary = foundationModelSummary
        self.repairDrafts = repairDrafts
        self.repairCandidates = repairCandidates.isEmpty
            ? RepairCandidatePresentationBuilder.build(
                findings: [],
                plan: plan,
                dispositions: findingDispositions
            )
            : repairCandidates
        self.repairCoverage = repairCoverage ?? RepairCoverageSummary(
            findingsReceived: findingDispositions.count,
            mechanicallyRepairable: findingDispositions.count {
                $0.kind == .automaticallySafe && !$0.hasConflict
            },
            modelProposed: findingDispositions.count {
                $0.kind == .foundationModelsProposal && !$0.hasConflict
            },
            reviewOnly: findingDispositions.count {
                $0.kind == .manualReviewRequired
            },
            conflicting: findingDispositions.count { $0.hasConflict },
            unsupported: findingDispositions.count {
                $0.kind == .notRepairable
            },
            planningFailures: plan.planningFailures.count
        )
    }
}
