//===--- ScanEngine.swift - SwiftDelta ------------------------------------------===//
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

/// Coordinates discovery, SDK-derived analysis, package inspection, and report
/// assembly for a single scan.
public struct ScanEngine: Sendable {
    private let discovery: ProjectDiscovery
    private let packageAnalyzer: PackageAnalyzer
    private let sdkAnalyzer: SDKAnalysisEngine
    private let environmentInspector: EnvironmentInspector
    private let containerInspector: XcodeContainerInspector
    private let settingsProvider: XcodeBuildSettingsProvider
    private let progress: OperationProgress

    public init(
        discovery: ProjectDiscovery = ProjectDiscovery(),
        packageAnalyzer: PackageAnalyzer = PackageAnalyzer(),
        runner: any ProcessRunning = ProcessRunner(),
        progress: OperationProgress = .silent
    ) {
        self.discovery = discovery
        self.packageAnalyzer = packageAnalyzer
        self.progress = progress
        sdkAnalyzer = SDKAnalysisEngine(runner: runner, progress: progress)
        environmentInspector = EnvironmentInspector(runner: runner)
        containerInspector = XcodeContainerInspector(runner: runner)
        settingsProvider = XcodeBuildSettingsProvider(runner: runner)
    }

    public func scan(_ request: ScanRequest) throws -> AnalysisReport {
        try request.configuration.validate(requireXcodePair: true)
        let discovered = try progress.phase(
            "Discovering project",
            completedMessage: "Discovered project"
        ) {
            try discovery.discover(
                root: request.root,
                excludedPaths: request.configuration.excludedPaths
            )
        }
        var effectiveConfiguration = request.configuration
        if effectiveConfiguration.sdkIdentifiers.isEmpty {
            effectiveConfiguration.sdkIdentifiers = try inferSDKIdentifiers(
                discovery: discovered,
                configuration: effectiveConfiguration,
                timeout: request.timeoutPerOperation,
                buildConfiguration: request.buildConfiguration,
                destination: request.destination
            )
        }
        let sdkOutput: SDKAnalysisOutput
        let blocked: Bool
        do {
            sdkOutput = try sdkAnalyzer.analyze(
                discovery: discovered,
                configuration: effectiveConfiguration,
                timeoutPerOperation: request.timeoutPerOperation,
                sdkCachePolicy: request.sdkCachePolicy,
                sdkCacheDirectory: request.sdkCacheDirectory,
                buildConfiguration: request.buildConfiguration,
                destination: request.destination
            )
            blocked = false
        } catch {
            sdkOutput = SDKAnalysisOutput(
                findings: [],
                failures: [
                    AnalysisFailure(
                        kind: .build,
                        message:
                            "SDK-derived analysis was blocked: "
                            + error.localizedDescription,
                        location: nil
                    ),
                ],
                baselineSnapshots: [],
                candidateSnapshots: [],
                referenceResolutionCoverage: []
            )
            blocked = true
        }
        var findings = sdkOutput.findings
        var failures = sdkOutput.failures
        var packageInspectionComplete = true

        for package in discovered.containers where package.kind == .package {
            do {
                let result = try packageAnalyzer.analyze(
                    manifestURL: URL(fileURLWithPath: package.path)
                )
                findings.append(contentsOf: result.findings)
                failures.append(contentsOf: result.failures)
            } catch {
                packageInspectionComplete = false
                failures.append(
                    AnalysisFailure(
                        kind: .parse,
                        message: "Could not inspect Package.swift metadata: \(error.localizedDescription)",
                        location: SourceLocation(path: package.path)
                    )
                )
            }
        }

        let filtered = FindingMerger.merge(findings).filter {
            $0.severity.isAtLeast(request.configuration.minimumSeverity)
                && $0.confidence.isAtLeast(request.configuration.minimumConfidence)
        }
        let baselineDeveloperDirectory = request.configuration.baselineXcodePath.flatMap {
            try? XcodeInstallation.validate(applicationPath: $0)
        }
        let candidateDeveloperDirectory = request.configuration.candidateXcodePath.flatMap {
            try? XcodeInstallation.validate(applicationPath: $0)
        }
        let baselineEnvironment = baselineDeveloperDirectory.map {
            environmentInspector.inspect(developerDirectory: $0)
        }
        let candidateEnvironment = candidateDeveloperDirectory.map {
            environmentInspector.inspect(developerDirectory: $0)
        }
        return AnalysisReport(
            projectRoot: discovered.root,
            targetXcodeVersion: candidateEnvironment?.xcodeVersion,
            environment: candidateEnvironment,
            baselineEnvironment: baselineEnvironment,
            candidateEnvironment: candidateEnvironment,
            analysisState: blocked
                ? .blocked
                : (sdkOutput.isComplete && packageInspectionComplete
                    ? nil : .incomplete),
            referenceResolutionCoverage: sdkOutput.referenceResolutionCoverage,
            sdkModuleSelections: sdkOutput.moduleSelections,
            findings: filtered,
            failures: failures
        )
    }

    private func inferSDKIdentifiers(
        discovery: DiscoveryResult,
        configuration: SwiftDeltaConfiguration,
        timeout: TimeInterval,
        buildConfiguration: String?,
        destination: String?
    ) throws -> [String] {
        var identifiers = Set<String>()
        let xcodeContainers = discovery.containers.filter {
            $0.kind == .project || $0.kind == .workspace
        }
        if !xcodeContainers.isEmpty,
           let candidateXcode = configuration.candidateXcodePath
        {
            let developerDirectory = try XcodeInstallation.validate(
                applicationPath: candidateXcode
            )
            let container = try discoveryForSelection(
                discovery,
                configuration: configuration
            )
            let details = try containerInspector.inspect(
                container,
                developerDirectory: developerDirectory,
                timeout: min(timeout, 30)
            )
            let scheme = try selectScheme(
                configured: configuration.defaultScheme,
                available: details.schemes
            )
            let settings = try settingsProvider.showBuildSettings(
                container: container,
                scheme: scheme,
                configuration: buildConfiguration,
                destination: destination,
                developerDirectory: developerDirectory,
                timeout: timeout
            )
            identifiers.formUnion(BuildSettingsAnalyzer().sdkIdentifiers(in: settings))
        }

        for package in discovery.containers where package.kind == .package {
            let result = try packageAnalyzer.analyze(
                manifestURL: URL(fileURLWithPath: package.path)
            )
            for platform in result.metadata.minimumPlatforms.keys {
                switch platform {
                case "iOS": identifiers.insert("iphoneos")
                case "macOS": identifiers.insert("macosx")
                case "tvOS": identifiers.insert("appletvos")
                case "watchOS": identifiers.insert("watchos")
                case "visionOS": identifiers.insert("xros")
                default: break
                }
            }
        }
        return identifiers.isEmpty ? ["macosx"] : identifiers.sorted()
    }

    private func discoveryForSelection(
        _ discovery: DiscoveryResult,
        configuration: SwiftDeltaConfiguration
    ) throws -> ProjectContainer {
        try self.discovery.selectXcodeContainer(
            from: discovery,
            project: configuration.defaultProject,
            workspace: configuration.defaultWorkspace
        )
    }

    public func selectScheme(
        configured: String?,
        available: [String]
    ) throws -> String {
        if let configured {
            guard available.contains(configured) else {
                throw SwiftDeltaError.invalidConfiguration(
                    field: "scheme",
                    reason: "'\(configured)' is not among the available schemes: \(available.joined(separator: ", "))"
                )
            }
            return configured
        }
        guard !available.isEmpty else {
            throw SwiftDeltaError.missingSelection("xcodebuild reported no shared schemes")
        }
        guard available.count == 1 else {
            throw SwiftDeltaError.ambiguousSelection(kind: "scheme", choices: available)
        }
        return available[0]
    }
}
