//===--- SDKAnalysisEngine.swift - SwiftDelta ------------------------------------------===//
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

public struct ScanRequest: Sendable {
    public let root: URL
    public let configuration: SwiftDeltaConfiguration
    public let timeoutPerOperation: TimeInterval
    public let sdkCachePolicy: SDKSnapshotCachePolicy
    public let sdkCacheDirectory: URL?
    public let buildConfiguration: String?
    public let destination: String?

    public init(
        root: URL,
        configuration: SwiftDeltaConfiguration,
        timeoutPerOperation: TimeInterval = 900,
        sdkCachePolicy: SDKSnapshotCachePolicy = .use,
        sdkCacheDirectory: URL? = nil,
        buildConfiguration: String? = nil,
        destination: String? = nil
    ) {
        self.root = root
        self.configuration = configuration
        self.timeoutPerOperation = timeoutPerOperation
        self.sdkCachePolicy = sdkCachePolicy
        self.sdkCacheDirectory = sdkCacheDirectory
        self.buildConfiguration = buildConfiguration
        self.destination = destination
    }
}

public struct SDKAnalysisOutput: Sendable {
    public let findings: [Finding]
    public let failures: [AnalysisFailure]
    public let baselineSnapshots: [SDKSnapshot]
    public let candidateSnapshots: [SDKSnapshot]
    public let baselineIdentities: [SDKInstallationIdentity]
    public let candidateIdentities: [SDKInstallationIdentity]
    public let references: [SDKSymbolReference]
    public let referenceResolutionCoverage: [ReferenceResolutionCoverage]
    public let baselineBuildContexts: [TargetBuildContext]
    public let candidateBuildContexts: [TargetBuildContext]
    public let candidateDiagnostics: [CompilerDiagnostic]
    public let moduleSelections: [SDKModuleSelectionEvidence]
    public let isComplete: Bool

    public init(
        findings: [Finding],
        failures: [AnalysisFailure],
        baselineSnapshots: [SDKSnapshot],
        candidateSnapshots: [SDKSnapshot],
        baselineIdentities: [SDKInstallationIdentity] = [],
        candidateIdentities: [SDKInstallationIdentity] = [],
        references: [SDKSymbolReference] = [],
        referenceResolutionCoverage: [ReferenceResolutionCoverage],
        baselineBuildContexts: [TargetBuildContext] = [],
        candidateBuildContexts: [TargetBuildContext] = [],
        candidateDiagnostics: [CompilerDiagnostic] = [],
        moduleSelections: [SDKModuleSelectionEvidence] = [],
        isComplete: Bool? = nil
    ) {
        self.findings = findings
        self.failures = failures
        self.baselineSnapshots = baselineSnapshots
        self.candidateSnapshots = candidateSnapshots
        self.baselineIdentities = baselineIdentities
        self.candidateIdentities = candidateIdentities
        self.references = references
        self.referenceResolutionCoverage = referenceResolutionCoverage
        self.baselineBuildContexts = baselineBuildContexts
        self.candidateBuildContexts = candidateBuildContexts
        self.candidateDiagnostics = candidateDiagnostics
        self.moduleSelections = moduleSelections
        self.isComplete = isComplete
            ?? !referenceResolutionCoverage.contains { !$0.isComplete }
    }
}

public struct SDKAnalysisEngine: Sendable {
    private let referenceResolver: CompilerReferenceResolver
    private let snapshotExtractor: SDKSnapshotExtractor
    private let contextProvider: TargetBuildContextProvider
    private let progress: OperationProgress

    public init(
        runner: any ProcessRunning = ProcessRunner(),
        progress: OperationProgress = .silent
    ) {
        self.progress = progress
        referenceResolver = CompilerReferenceResolver(runner: runner)
        snapshotExtractor = SDKSnapshotExtractor(runner: runner, progress: progress)
        contextProvider = TargetBuildContextProvider(runner: runner)
    }

    public func analyze(
        discovery: DiscoveryResult,
        configuration: SwiftDeltaConfiguration,
        timeoutPerOperation: TimeInterval = 900,
        sdkCachePolicy: SDKSnapshotCachePolicy = .use,
        sdkCacheDirectory: URL? = nil,
        buildConfiguration: String? = nil,
        destination: String? = nil,
        cancellation: @escaping @Sendable () -> Bool = { false }
    ) throws -> SDKAnalysisOutput {
        try configuration.validate(requireXcodePair: true)
        try BuildContextSelectionValidator.validate(
            sdkIdentifiers: configuration.sdkIdentifiers,
            destination: destination
        )
        guard let baselineXcode = configuration.baselineXcodePath,
              let candidateXcode = configuration.candidateXcodePath
        else {
            throw SwiftDeltaError.missingSelection(
                "baseline and candidate Xcode applications"
            )
        }

        var findings: [Finding] = []
        var failures: [AnalysisFailure] = []
        var baselineSnapshots: [SDKSnapshot] = []
        var candidateSnapshots: [SDKSnapshot] = []
        var baselineIdentities: [SDKInstallationIdentity] = []
        var candidateIdentities: [SDKInstallationIdentity] = []
        var resolvedReferences: [SDKSymbolReference] = []
        var referenceResolutionCoverage: [ReferenceResolutionCoverage] = []
        var baselineBuildContexts: [TargetBuildContext] = []
        var candidateBuildContexts: [TargetBuildContext] = []
        var candidateDiagnostics: [CompilerDiagnostic] = []
        var moduleSelections: [SDKModuleSelectionEvidence] = []
        var analysisComplete = true
        let projectRoot = URL(fileURLWithPath: discovery.root, isDirectory: true)
        let selectionsUseSameToolchain = canonicalApplicationPath(
            baselineXcode
        ) == canonicalApplicationPath(candidateXcode)

        for sdkIdentifier in configuration.sdkIdentifiers {
            do {
            let baselineContext = try resolveContexts(
                discovery: discovery,
                configuration: configuration,
                xcodeApplicationPath: baselineXcode,
                role: "baseline",
                sdkIdentifier: sdkIdentifier,
                buildConfiguration: buildConfiguration,
                destination: destination,
                timeout: timeoutPerOperation,
                cancellation: cancellation
            )
            failures.append(contentsOf: baselineContext.failures)
            if !baselineContext.failures.isEmpty {
                analysisComplete = false
            }
            baselineBuildContexts.append(contentsOf: baselineContext.contexts)
            if let identity = baselineContext.sdkIdentity {
                baselineIdentities.append(identity)
            }
            let references = try progress.phase(
                "Resolving baseline references for \(baselineContext.contexts.count) target(s) on \(sdkIdentifier)",
                completedMessage: "Resolved compiler references for \(sdkIdentifier)"
            ) {
                try resolve(
                    contexts: baselineContext.contexts,
                    projectRoot: projectRoot,
                    timeout: timeoutPerOperation,
                    cancellation: cancellation
                )
            }
            failures.append(contentsOf: references.failures)
            if references.coverage.contains(where: { !$0.isComplete }) {
                analysisComplete = false
            }
            moduleSelections.append(contentsOf: references.moduleSelections)
            resolvedReferences.append(contentsOf: references.references)
            referenceResolutionCoverage.append(contentsOf: references.coverage)
            for coverage in references.coverage
                where coverage.unresolvedReferences > 0
            {
                let reasons = coverage.unresolvedReasons
                    .sorted { $0.key < $1.key }
                    .map { "\($0.value) \($0.key)" }
                    .joined(separator: "; ")
                failures.append(
                    AnalysisFailure(
                        kind: .parse,
                        message:
                            "Compiler reference coverage for \(sdkIdentifier)"
                            + "\(coverage.target.map { " target \($0)" } ?? ""): "
                            + "\(coverage.unresolvedReferences) of "
                            + "\(coverage.declarationReferences) declaration reference(s) "
                            + "were unresolved and excluded from confirmed SDK matching"
                            + (reasons.isEmpty ? "." : " (\(reasons))."),
                        location: nil
                    )
                )
            }
            let candidateReferences: ContextReferenceResolution
            let candidateIdentity: SDKInstallationIdentity?
            if selectionsUseSameToolchain {
                // Reuse identical compiler evidence while retaining
                // role-specific coverage.
                candidateIdentity = baselineContext.sdkIdentity
                candidateBuildContexts.append(
                    contentsOf: baselineContext.contexts.map {
                        relabel($0, role: "candidate")
                    }
                )
                candidateReferences = ContextReferenceResolution(
                    references: references.references,
                    importedModules: references.importedModules,
                    failures: references.failures,
                    coverage: references.coverage.map {
                        relabel($0, role: "candidate")
                    },
                    diagnostics: references.diagnostics,
                    moduleSelections: references.moduleSelections.map {
                        SDKModuleSelectionEvidence(
                            toolchainRole: "candidate",
                            sdkIdentifier: $0.sdkIdentifier,
                            moduleName: $0.moduleName,
                            target: $0.target,
                            reason: $0.reason,
                            sourcePaths: $0.sourcePaths
                        )
                    }
                )
                moduleSelections.append(
                    contentsOf: candidateReferences.moduleSelections
                )
                referenceResolutionCoverage.append(
                    contentsOf: candidateReferences.coverage
                )
                candidateDiagnostics.append(
                    contentsOf: candidateReferences.diagnostics
                )
                progress.message(
                    "Reusing compiler references because baseline and candidate "
                        + "select the same Xcode"
                )
            } else {
                let candidateContext = try resolveContexts(
                    discovery: discovery,
                    configuration: configuration,
                    xcodeApplicationPath: candidateXcode,
                    role: "candidate",
                    sdkIdentifier: sdkIdentifier,
                    buildConfiguration: buildConfiguration,
                    destination: destination,
                    timeout: timeoutPerOperation,
                    cancellation: cancellation
                )
                candidateIdentity = candidateContext.sdkIdentity
                failures.append(contentsOf: candidateContext.failures)
                if !candidateContext.failures.isEmpty {
                    analysisComplete = false
                }
                candidateBuildContexts.append(
                    contentsOf: candidateContext.contexts
                )
                candidateReferences = try progress.phase(
                    "Resolving candidate references for \(candidateContext.contexts.count) target(s) on \(sdkIdentifier)",
                    completedMessage: "Resolved candidate compiler references for \(sdkIdentifier)"
                ) {
                    try resolve(
                        contexts: candidateContext.contexts,
                        projectRoot: projectRoot,
                        timeout: timeoutPerOperation,
                        cancellation: cancellation
                    )
                }
                failures.append(contentsOf: candidateReferences.failures)
                if candidateReferences.coverage.contains(where: { !$0.isComplete }) {
                    analysisComplete = false
                }
                moduleSelections.append(
                    contentsOf: candidateReferences.moduleSelections
                )
                referenceResolutionCoverage.append(
                    contentsOf: candidateReferences.coverage
                )
                candidateDiagnostics.append(
                    contentsOf: candidateReferences.diagnostics
                )
            }
            if let candidateIdentity {
                candidateIdentities.append(candidateIdentity)
            }
            let modules = Set(
                references.importedModules + candidateReferences.importedModules
            ).sorted().filter {
                !$0.hasPrefix("_") && $0 != "SwiftDeltaAnalyzedTarget"
            }
            if modules.isEmpty {
                analysisComplete = false
                failures.append(
                    AnalysisFailure(
                        kind: .discovery,
                        message: "No active imported SDK modules were resolved for \(sdkIdentifier); SDK extraction was skipped.",
                        location: nil
                    )
                )
                continue
            }

            let baseline = try progress.phase(
                "Extracting baseline \(sdkIdentifier) SDK metadata",
                completedMessage: "Extracted baseline \(sdkIdentifier) SDK metadata"
            ) {
                try snapshotExtractor.extract(
                    SDKSnapshotRequest(
                        xcodeApplicationPath: baselineXcode,
                        sdkIdentifier: sdkIdentifier,
                        modules: modules,
                        timeout: timeoutPerOperation,
                        cachePolicy: sdkCachePolicy,
                        cacheDirectory: sdkCacheDirectory,
                        installationIdentity: baselineContext.sdkIdentity
                    ),
                    cancellation: cancellation
                )
            }
            let candidate = try progress.phase(
                "Extracting candidate \(sdkIdentifier) SDK metadata",
                completedMessage: "Extracted candidate \(sdkIdentifier) SDK metadata"
            ) {
                try snapshotExtractor.extract(
                    SDKSnapshotRequest(
                        xcodeApplicationPath: candidateXcode,
                        sdkIdentifier: sdkIdentifier,
                        modules: modules,
                        timeout: timeoutPerOperation,
                        cachePolicy: sdkCachePolicy,
                        cacheDirectory: sdkCacheDirectory,
                        installationIdentity: candidateIdentity
                    ),
                    cancellation: cancellation
                )
            }
            baselineSnapshots.append(baseline)
            candidateSnapshots.append(candidate)
            for warning in baseline.extractionWarnings {
                failures.append(
                    AnalysisFailure(
                        kind: .discovery,
                        message: "Baseline SDK extraction: \(warning)",
                        location: nil
                    )
                )
            }
            for warning in candidate.extractionWarnings {
                failures.append(
                    AnalysisFailure(
                        kind: .discovery,
                        message: "Candidate SDK extraction: \(warning)",
                        location: nil
                    )
                )
            }
            let comparableModules = baseline.successfullyExtractedModules
                .intersection(candidate.successfullyExtractedModules)
            let unavailableModules = Set(modules).subtracting(comparableModules)
            if !unavailableModules.isEmpty {
                analysisComplete = false
            }
            for module in unavailableModules.sorted() {
                failures.append(
                    AnalysisFailure(
                        kind: .discovery,
                        message:
                            "SDK comparison skipped module \(module) for \(sdkIdentifier) because "
                            + "one or both selected toolchains did not produce usable structured "
                            + "or interface metadata. Extraction details are reported above.",
                        location: nil
                    )
                )
            }
            let changes = progress.phase(
                "Comparing normalized \(sdkIdentifier) SDK snapshots",
                completedMessage: "Compared normalized \(sdkIdentifier) SDK snapshots"
            ) {
                SDKSnapshotDiffer.compare(
                    baseline: baseline,
                    candidate: candidate
                ).filter { comparableModules.contains($0.baseline.moduleName) }
            }
            findings.append(
                contentsOf: SDKProjectMatcher.findings(
                    changes: changes,
                    references: references.references,
                    candidateReferences: candidateReferences.references,
                    candidateDiagnostics: candidateReferences.diagnostics,
                    candidateCompleteTargets: Set(
                        candidateReferences.coverage.compactMap {
                            $0.isComplete ? $0.target : nil
                        }
                    ),
                    baseline: baseline,
                    candidate: candidate
                )
            )
            } catch let error as SwiftDeltaError {
                if case .processCancelled = error {
                    throw error
                }
                analysisComplete = false
                failures.append(
                    AnalysisFailure(
                        kind: .discovery,
                        message:
                            "Analysis for SDK \(sdkIdentifier) could not complete: "
                            + error.localizedDescription
                            + " Independent SDK contexts will continue.",
                        location: nil
                    )
                )
            } catch {
                analysisComplete = false
                failures.append(
                    AnalysisFailure(
                        kind: .discovery,
                        message:
                            "Analysis for SDK \(sdkIdentifier) could not complete: "
                            + error.localizedDescription
                            + " Independent SDK contexts will continue.",
                        location: nil
                    )
                )
            }
        }
        return SDKAnalysisOutput(
            findings: FindingMerger.merge(findings),
            failures: failures,
            baselineSnapshots: baselineSnapshots,
            candidateSnapshots: candidateSnapshots,
            baselineIdentities: uniqueIdentities(baselineIdentities),
            candidateIdentities: uniqueIdentities(candidateIdentities),
            references: resolvedReferences,
            referenceResolutionCoverage: referenceResolutionCoverage,
            baselineBuildContexts: baselineBuildContexts,
            candidateBuildContexts: candidateBuildContexts,
            candidateDiagnostics:
                CompilerDiagnosticParser.deduplicate(candidateDiagnostics),
            moduleSelections: Array(Set(moduleSelections)).sorted {
                (
                    $0.sdkIdentifier,
                    $0.moduleName,
                    $0.toolchainRole,
                    $0.target ?? ""
                ) < (
                    $1.sdkIdentifier,
                    $1.moduleName,
                    $1.toolchainRole,
                    $1.target ?? ""
                )
            },
            isComplete: analysisComplete
        )
    }

    private struct ContextReferenceResolution {
        let references: [SDKSymbolReference]
        let importedModules: [String]
        let failures: [AnalysisFailure]
        let coverage: [ReferenceResolutionCoverage]
        let diagnostics: [CompilerDiagnostic]
        let moduleSelections: [SDKModuleSelectionEvidence]
    }

    private func resolve(
        contexts: [TargetBuildContext],
        projectRoot: URL,
        timeout: TimeInterval,
        cancellation: @escaping @Sendable () -> Bool
    ) throws -> ContextReferenceResolution {
        var references: [SDKSymbolReference] = []
        var modules = Set<String>()
        var failures: [AnalysisFailure] = []
        var coverage: [ReferenceResolutionCoverage] = []
        var diagnostics: [CompilerDiagnostic] = []
        var selections: [SDKModuleSelectionEvidence] = []
        for (contextIndex, context) in contexts.enumerated() {
            progress.measure(
                completed: contextIndex,
                total: contexts.count,
                label: "Compiler targets"
            )
            let result: CompilerReferenceResolutionResult
            do {
                result = try referenceResolver.resolve(
                    CompilerReferenceRequest(
                        buildContext: context,
                        projectRoot: projectRoot,
                        timeoutPerFile: timeout
                    ),
                    cancellation: cancellation
                )
            } catch let error as SwiftDeltaError {
                if case .processCancelled = error {
                    throw error
                }
                appendResolutionFailure(
                    error,
                    context: context,
                    failures: &failures,
                    coverage: &coverage,
                    modules: &modules,
                    selections: &selections
                )
                continue
            } catch {
                appendResolutionFailure(
                    error,
                    context: context,
                    failures: &failures,
                    coverage: &coverage,
                    modules: &modules,
                    selections: &selections
                )
                continue
            }
            references.append(contentsOf: result.references)
            modules.formUnion(result.importedModules)
            failures.append(contentsOf: result.failures)
            coverage.append(result.coverage)
            diagnostics.append(contentsOf: result.diagnostics)
            for module in result.importedModules {
                let paths = result.importedModulesBySource.compactMap {
                    $0.value.contains(module) ? $0.key : nil
                }.sorted()
                selections.append(
                    SDKModuleSelectionEvidence(
                        toolchainRole: context.toolchainRole,
                        sdkIdentifier: context.sdkIdentifier,
                        moduleName: module,
                        target: context.target,
                        reason:
                            "active compiler import in the selected target context",
                        sourcePaths: paths
                    )
                )
            }
            for evidence in additionalModuleSelections(context: context) {
                modules.insert(evidence.moduleName)
                selections.append(evidence)
            }
            progress.measure(
                completed: contextIndex + 1,
                total: contexts.count,
                label: "Compiler targets"
            )
        }
        return ContextReferenceResolution(
            references: references,
            importedModules: modules.sorted(),
            failures: failures,
            coverage: coverage,
            diagnostics: CompilerDiagnosticParser.deduplicate(diagnostics),
            moduleSelections: selections
        )
    }

    private func appendResolutionFailure(
        _ error: any Error,
        context: TargetBuildContext,
        failures: inout [AnalysisFailure],
        coverage: inout [ReferenceResolutionCoverage],
        modules: inout Set<String>,
        selections: inout [SDKModuleSelectionEvidence]
    ) {
        failures.append(
            AnalysisFailure(
                kind: .parse,
                message:
                    "Compiler reference resolution failed for target "
                    + "\(context.target): \(error.localizedDescription). "
                    + "Independent target contexts will continue.",
                location: context.containerPath.map {
                    SourceLocation(path: $0)
                }
            )
        )
        coverage.append(
            ReferenceResolutionCoverage(
                sdkIdentifier: context.sdkIdentifier,
                toolchainRole: context.toolchainRole,
                xcodeIdentity: context.xcodeIdentity,
                swiftIdentity: context.swiftIdentity,
                platform: context.platform,
                scheme: context.scheme,
                target: context.target,
                configuration: context.configuration,
                destination: context.destination,
                architecture: context.architecture,
                deploymentTarget: context.deploymentTarget,
                filesRequested: context.analysisSourceFiles.count,
                filesAnalyzed: 0,
                filesFailed: context.analysisSourceFiles.count,
                unresolvedReasons: [
                    "resolver-failed": context.analysisSourceFiles.count,
                ],
                isComplete: false,
                sourceFiles: context.analysisSourceFiles.map {
                    SourceAnalysisRecord(
                        path: $0,
                        disposition: .failed,
                        reason: error.localizedDescription
                    )
                }
            )
        )
        for evidence in additionalModuleSelections(context: context) {
            modules.insert(evidence.moduleName)
            selections.append(evidence)
        }
    }

    private func additionalModuleSelections(
        context: TargetBuildContext
    ) -> [SDKModuleSelectionEvidence] {
        var reasons: [String: Set<String>] = [:]
        var paths: [String: Set<String>] = [:]
        let arguments = context.compilerArguments
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "-framework", arguments.indices.contains(index + 1) {
                reasons[arguments[index + 1], default: []].insert(
                    "framework dependency in the selected compiler context"
                )
                index += 2
                continue
            }
            let moduleMapPrefix = "-fmodule-map-file="
            let moduleMapArgument: String?
            if argument.hasPrefix(moduleMapPrefix) {
                moduleMapArgument = String(argument.dropFirst(moduleMapPrefix.count))
            } else if argument == "-Xcc",
                      arguments.indices.contains(index + 1),
                      arguments[index + 1].hasPrefix(moduleMapPrefix)
            {
                moduleMapArgument = String(
                    arguments[index + 1].dropFirst(moduleMapPrefix.count)
                )
                index += 1
            } else {
                moduleMapArgument = nil
            }
            if let moduleMapArgument,
               URL(fileURLWithPath: moduleMapArgument)
                    .standardizedFileURL.path.hasPrefix(
                        URL(fileURLWithPath: context.sdkPath)
                            .standardizedFileURL.path + "/"
                    ),
               let contents = try? String(
                    contentsOfFile: moduleMapArgument,
                    encoding: .utf8
               )
            {
                for module in clangModuleNames(contents) {
                    reasons[module, default: []].insert(
                        "SDK module map in the selected compiler context"
                    )
                    paths[module, default: []].insert(moduleMapArgument)
                }
            }
            index += 1
        }
        if let bridgingHeader = context.bridgingHeader,
           let contents = try? String(
               contentsOfFile: bridgingHeader,
               encoding: .utf8
           )
        {
            for module in bridgingHeaderModules(contents) {
                reasons[module, default: []].insert(
                    "Clang import in the selected bridging header"
                )
                paths[module, default: []].insert(bridgingHeader)
            }
        }
        let localModules = Set(
            context.targetDependencies + [context.moduleName, context.target]
        )
        return reasons.compactMap { module, values in
            guard !module.isEmpty,
                  !module.hasPrefix("_"),
                  !localModules.contains(module)
            else {
                return nil
            }
            return SDKModuleSelectionEvidence(
                toolchainRole: context.toolchainRole,
                sdkIdentifier: context.sdkIdentifier,
                moduleName: module,
                target: context.target,
                reason: values.sorted().joined(separator: "; "),
                sourcePaths: Array(paths[module] ?? []).sorted()
            )
        }.sorted {
            ($0.moduleName, $0.reason) < ($1.moduleName, $1.reason)
        }
    }

    private func clangModuleNames(_ source: String) -> [String] {
        matches(
            #"(?:^|\n)\s*(?:explicit\s+)?(?:framework\s+)?module\s+([A-Za-z_][A-Za-z0-9_.]*)"#,
            in: source
        )
    }

    private func bridgingHeaderModules(_ source: String) -> [String] {
        let atImports = matches(
            #"@import\s+([A-Za-z_][A-Za-z0-9_.]*)\s*;"#,
            in: source
        )
        let includeImports = matches(
            #"#\s*(?:import|include)\s*[<"]([A-Za-z_][A-Za-z0-9_]*)/"#,
            in: source
        )
        return Array(Set(atImports + includeImports)).sorted()
    }

    private func matches(_ pattern: String, in source: String) -> [String] {
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.anchorsMatchLines]
        ) else {
            return []
        }
        let range = NSRange(source.startIndex..., in: source)
        return expression.matches(in: source, range: range).compactMap {
            guard let match = Range($0.range(at: 1), in: source) else {
                return nil
            }
            return String(source[match])
        }
    }

    private func resolveContexts(
        discovery: DiscoveryResult,
        configuration: SwiftDeltaConfiguration,
        xcodeApplicationPath: String,
        role: String,
        sdkIdentifier: String,
        buildConfiguration: String?,
        destination: String?,
        timeout: TimeInterval,
        cancellation: @escaping @Sendable () -> Bool
    ) throws -> TargetBuildContextResolution {
        if discovery.containers.isEmpty {
            let identity = try snapshotExtractor.inspectIdentity(
                xcodeApplicationPath: xcodeApplicationPath,
                sdkIdentifier: sdkIdentifier,
                timeout: min(timeout, 120)
            )
            let fallback = TargetBuildContext(
                toolchainRole: role,
                xcodeApplicationPath: xcodeApplicationPath,
                xcodeIdentity:
                    "Xcode \(identity.xcodeVersion) (\(identity.xcodeBuild))",
                swiftIdentity: identity.swiftVersion,
                sdkIdentifier: sdkIdentifier,
                sdkPath: identity.sdkPath,
                platform: identity.platform,
                target: "<unresolved target>",
                moduleName: "SwiftDeltaAnalyzedTarget",
                configuration: buildConfiguration,
                destination: destination,
                architecture: "arm64",
                deploymentTarget: "0",
                activeCompilationConditions:
                    configuration.activeCompilationConditions,
                sourceFiles: discovery.swiftFiles,
                compilerArguments: [],
                evidenceSource: .configuredFallback,
                isAuthoritative: false
            )
            return TargetBuildContextResolution(
                contexts: [fallback],
                failures: [
                    AnalysisFailure(
                        kind: .discovery,
                        message:
                            "No Xcode project, workspace, or Package.swift was selected; "
                            + "target membership and deployment context are incomplete.",
                        location: nil
                    ),
                ],
                excludedSourceFiles: [],
                sdkIdentity: identity
            )
        }
        return try contextProvider.resolve(
            discovery: discovery,
            configuration: configuration,
            xcodeApplicationPath: xcodeApplicationPath,
            toolchainRole: role,
            sdkIdentifier: sdkIdentifier,
            buildConfiguration: buildConfiguration,
            destination: destination,
            timeout: timeout,
            cancellation: cancellation
        )
    }

    private func canonicalApplicationPath(_ value: String) -> String {
        URL(fileURLWithPath: value)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private func uniqueIdentities(
        _ identities: [SDKInstallationIdentity]
    ) -> [SDKInstallationIdentity] {
        var seen = Set<String>()
        return identities.filter {
            seen.insert(
                "\($0.xcodeBuild)|\($0.sdkIdentifier)|\($0.sdkVersion)|\($0.sdkPath)"
            ).inserted
        }
    }

    private func relabel(
        _ value: ReferenceResolutionCoverage,
        role: String
    ) -> ReferenceResolutionCoverage {
        ReferenceResolutionCoverage(
            sdkIdentifier: value.sdkIdentifier,
            toolchainRole: role,
            xcodeIdentity: value.xcodeIdentity,
            swiftIdentity: value.swiftIdentity,
            platform: value.platform,
            scheme: value.scheme,
            target: value.target,
            configuration: value.configuration,
            destination: value.destination,
            architecture: value.architecture,
            deploymentTarget: value.deploymentTarget,
            filesRequested: value.filesRequested,
            filesAnalyzed: value.filesAnalyzed,
            filesWithoutSDKReferences: value.filesWithoutSDKReferences,
            filesFailed: value.filesFailed,
            declarationReferences: value.declarationReferences,
            stableIdentityReferences: value.stableIdentityReferences,
            unresolvedReferences: value.unresolvedReferences,
            unresolvedReasons: value.unresolvedReasons,
            compilerExitStatus: value.compilerExitStatus,
            isComplete: value.isComplete,
            sourceFiles: value.sourceFiles
        )
    }

    private func relabel(
        _ value: TargetBuildContext,
        role: String
    ) -> TargetBuildContext {
        TargetBuildContext(
            toolchainRole: role,
            xcodeApplicationPath: value.xcodeApplicationPath,
            xcodeIdentity: value.xcodeIdentity,
            swiftIdentity: value.swiftIdentity,
            sdkIdentifier: value.sdkIdentifier,
            sdkPath: value.sdkPath,
            platform: value.platform,
            platformVariant: value.platformVariant,
            containerPath: value.containerPath,
            projectPath: value.projectPath,
            scheme: value.scheme,
            target: value.target,
            moduleName: value.moduleName,
            configuration: value.configuration,
            destination: value.destination,
            architecture: value.architecture,
            deploymentTarget: value.deploymentTarget,
            swiftLanguageVersion: value.swiftLanguageVersion,
            activeCompilationConditions: value.activeCompilationConditions,
            otherSwiftFlags: value.otherSwiftFlags,
            frameworkSearchPaths: value.frameworkSearchPaths,
            headerSearchPaths: value.headerSearchPaths,
            moduleSearchPaths: value.moduleSearchPaths,
            bridgingHeader: value.bridgingHeader,
            strictConcurrency: value.strictConcurrency,
            targetDependencies: value.targetDependencies,
            sourceFiles: value.sourceFiles,
            analysisSourceFiles: value.analysisSourceFiles,
            generatedSourceFiles: value.generatedSourceFiles,
            nativeSourceFiles: value.nativeSourceFiles,
            excludedSourceFiles: value.excludedSourceFiles,
            buildArtifactRoot: value.buildArtifactRoot,
            capturedCompilerExecutable: value.capturedCompilerExecutable,
            capturedCompilerArguments: value.capturedCompilerArguments,
            compilerArguments: value.compilerArguments,
            evidenceSource: value.evidenceSource,
            isAuthoritative: value.isAuthoritative
        )
    }
}
