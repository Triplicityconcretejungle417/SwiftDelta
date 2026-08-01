//===--- TUIOperationService+Analysis.swift - SwiftDelta ------------------------------------------===//
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

extension CoreTUIOperationService {
    func scan(
        root: URL,
        workflow: TUIWorkflowSettings,
        runner: any ProcessRunning,
        progress: OperationProgress
    ) throws -> AnalysisReport {
        let configuration = try effectiveConfiguration(
            root: root,
            workflow: workflow
        )
        return try ScanEngine(runner: runner, progress: progress).scan(
            ScanRequest(
                root: root,
                configuration: configuration,
                timeoutPerOperation: workflow.timeout,
                sdkCachePolicy: workflow.sdkCachePolicy,
                buildConfiguration: workflow.buildConfiguration,
                destination: workflow.destination
            )
        )
    }

    func compare(
        root: URL,
        workflow: TUIWorkflowSettings,
        runner: any ProcessRunning,
        progress: OperationProgress,
        cancellation: @escaping @Sendable () -> Bool
    ) throws -> AnalysisReport {
        guard let baseline = workflow.baselineXcodePath,
              let candidate = workflow.candidateXcodePath
        else {
            throw SwiftDeltaError.missingSelection(
                "baseline and candidate Xcode applications"
            )
        }
        let configuration = try effectiveConfiguration(
            root: root,
            workflow: workflow
        )
        let baselineDeveloperDirectory = try XcodeInstallation.validate(
            applicationPath: baseline
        )
        let candidateDeveloperDirectory = try XcodeInstallation.validate(
            applicationPath: candidate
        )
        let discovered = try ProjectDiscovery().discover(
            root: root,
            excludedPaths: configuration.excludedPaths
        )
        let container = try ProjectDiscovery().selectBuildContainer(
            from: discovered,
            project: configuration.defaultProject,
            workspace: configuration.defaultWorkspace
        )
        let selectedScheme: String
        if container.kind == .package {
            selectedScheme = ""
        } else {
            let details = try XcodeContainerInspector(runner: runner).inspect(
                container,
                developerDirectory: candidateDeveloperDirectory,
                timeout: min(workflow.timeout, 30)
            )
            selectedScheme = try ScanEngine().selectScheme(
                configured: configuration.defaultScheme,
                available: details.schemes
            )
        }
        let staticReport = try ScanEngine(
            runner: runner,
            progress: progress
        ).scan(
            ScanRequest(
                root: root,
                configuration: configuration,
                timeoutPerOperation: workflow.timeout,
                sdkCachePolicy: workflow.sdkCachePolicy,
                buildConfiguration: workflow.buildConfiguration,
                destination: workflow.destination
            )
        )
        guard staticReport.analysisState != .blocked else {
            return staticReport
        }
        let inspector = EnvironmentInspector(runner: runner)
        let baselineEnvironment = inspector.inspect(
            developerDirectory: baselineDeveloperDirectory
        )
        let candidateEnvironment = inspector.inspect(
            developerDirectory: candidateDeveloperDirectory
        )
        let baselineIdentity = condensed(baselineEnvironment.xcodeVersion)
        let candidateIdentity = condensed(candidateEnvironment.xcodeVersion)
        let candidateVersion = candidateEnvironment.xcodeVersion?
            .split(whereSeparator: \.isNewline).first.map(String.init)
        let identifiers = configuration.sdkIdentifiers.isEmpty
            ? Array(
                Set(
                    staticReport.referenceResolutionCoverage.map(
                        \.sdkIdentifier
                    )
                )
            ).sorted()
            : configuration.sdkIdentifiers
        let matrix: [String?] = identifiers.isEmpty
            ? [nil]
            : identifiers.map(Optional.some)
        var findings: [Finding] = []
        do {
            for (index, identifier) in matrix.enumerated() {
                let comparator = BuildComparator(
                    builder: XcodeProjectBuilder(
                        runner: runner,
                        progress: progress
                    )
                )
                let result = try comparator.compare(
                    old: BuildInvocation(
                        xcodePath: baseline,
                        container: container,
                        scheme: selectedScheme,
                        configuration: workflow.buildConfiguration,
                        destination: workflow.destination,
                        timeout: workflow.timeout,
                        sdkIdentifiers: identifier.map { [$0] } ?? [],
                        xcodeIdentity: baselineIdentity
                    ),
                    new: BuildInvocation(
                        xcodePath: candidate,
                        container: container,
                        scheme: selectedScheme,
                        configuration: workflow.buildConfiguration,
                        destination: workflow.destination,
                        timeout: workflow.timeout,
                        sdkIdentifiers: identifier.map { [$0] } ?? [],
                        xcodeIdentity: candidateIdentity
                    ),
                    staticFindings: index == 0 ? staticReport.findings : [],
                    targetVersion: candidateVersion,
                    cancellation: cancellation
                )
                findings.append(contentsOf: result.findings)
            }
        } catch {
            return AnalysisReport(
                projectRoot: root.path,
                targetXcodeVersion: candidateVersion,
                environment: candidateEnvironment,
                baselineEnvironment: baselineEnvironment,
                candidateEnvironment: candidateEnvironment,
                analysisState: .blocked,
                referenceResolutionCoverage:
                    staticReport.referenceResolutionCoverage,
                sdkModuleSelections: staticReport.sdkModuleSelections,
                findings: staticReport.findings,
                failures: staticReport.failures + [
                    AnalysisFailure(
                        kind: .build,
                        message:
                            "Build comparison was blocked: "
                            + error.localizedDescription,
                        location: nil
                    ),
                ]
            )
        }
        let filtered = FindingMerger.merge(findings).filter {
            $0.severity.isAtLeast(configuration.minimumSeverity)
                && $0.confidence.isAtLeast(configuration.minimumConfidence)
        }
        return AnalysisReport(
            projectRoot: root.path,
            targetXcodeVersion: candidateVersion,
            environment: candidateEnvironment,
            baselineEnvironment: baselineEnvironment,
            candidateEnvironment: candidateEnvironment,
            analysisState: staticReport.analysisState == .incomplete
                ? .incomplete : nil,
            referenceResolutionCoverage:
                staticReport.referenceResolutionCoverage,
            sdkModuleSelections: staticReport.sdkModuleSelections,
            findings: filtered,
            failures: staticReport.failures
        )
    }

}
