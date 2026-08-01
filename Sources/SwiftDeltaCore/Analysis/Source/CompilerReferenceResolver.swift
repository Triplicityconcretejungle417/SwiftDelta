//===--- CompilerReferenceResolver.swift - SwiftDelta ------------------------------------------===//
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

public struct CompilerReferenceFileMetrics: Hashable, Sendable {
    public let declarationReferences: Int
    public let stableIdentityReferences: Int
    public let unresolvedReferences: Int
    public let unresolvedReasons: [String: Int]

    public init(
        declarationReferences: Int,
        stableIdentityReferences: Int,
        unresolvedReferences: Int,
        unresolvedReasons: [String: Int]
    ) {
        self.declarationReferences = declarationReferences
        self.stableIdentityReferences = stableIdentityReferences
        self.unresolvedReferences = unresolvedReferences
        self.unresolvedReasons = unresolvedReasons
    }
}

public struct CompilerReferenceResolutionResult: Sendable {
    public let references: [SDKSymbolReference]
    public let importedModules: [String]
    public let failures: [AnalysisFailure]
    public let coverage: ReferenceResolutionCoverage
    public let diagnostics: [CompilerDiagnostic]
    public let importedModulesBySource: [String: [String]]
    public let metricsBySource: [String: CompilerReferenceFileMetrics]

    public init(
        references: [SDKSymbolReference],
        importedModules: [String],
        failures: [AnalysisFailure],
        coverage: ReferenceResolutionCoverage = ReferenceResolutionCoverage(
            sdkIdentifier: ""
        ),
        diagnostics: [CompilerDiagnostic] = [],
        importedModulesBySource: [String: [String]] = [:],
        metricsBySource: [String: CompilerReferenceFileMetrics] = [:]
    ) {
        self.references = references
        self.importedModules = importedModules
        self.failures = failures
        self.coverage = coverage
        self.diagnostics = diagnostics
        self.importedModulesBySource = importedModulesBySource
        self.metricsBySource = metricsBySource
    }
}

public struct CompilerReferenceRequest: Sendable {
    public let files: [URL]
    public let projectRoot: URL
    public let xcodeApplicationPath: String
    public let sdkIdentifier: String
    public let activeCompilationConditions: [String]
    public let timeoutPerFile: TimeInterval
    public let toolchainRole: String
    public let buildContext: TargetBuildContext?

    public init(
        files: [URL],
        projectRoot: URL,
        xcodeApplicationPath: String,
        sdkIdentifier: String,
        activeCompilationConditions: [String] = [],
        timeoutPerFile: TimeInterval = 60,
        toolchainRole: String = "selected",
        buildContext: TargetBuildContext? = nil
    ) {
        self.files = files
        self.projectRoot = projectRoot
        self.xcodeApplicationPath = xcodeApplicationPath
        self.sdkIdentifier = sdkIdentifier
        self.activeCompilationConditions = activeCompilationConditions
        self.timeoutPerFile = timeoutPerFile
        self.toolchainRole = toolchainRole
        self.buildContext = buildContext
    }

    public init(
        buildContext: TargetBuildContext,
        projectRoot: URL,
        timeoutPerFile: TimeInterval = 60
    ) {
        files = buildContext.sourceFiles.map(URL.init(fileURLWithPath:))
        self.projectRoot = projectRoot
        xcodeApplicationPath = buildContext.xcodeApplicationPath
        sdkIdentifier = buildContext.sdkIdentifier
        activeCompilationConditions = buildContext.activeCompilationConditions
        self.timeoutPerFile = timeoutPerFile
        toolchainRole = buildContext.toolchainRole
        self.buildContext = buildContext
    }
}

/// Uses target-specific compiler evidence to resolve source references.
///
/// Requests without a build context are retained for source compatibility, but
/// their reconstructed arguments are explicitly incomplete and non-authoritative.
public struct CompilerReferenceResolver: Sendable {
    private let runner: any ProcessRunning
    public let maximumFileSize: Int

    public init(
        runner: any ProcessRunning = ProcessRunner(),
        maximumFileSize: Int = 5 * 1_024 * 1_024
    ) {
        self.runner = runner
        self.maximumFileSize = maximumFileSize
    }

    public func resolve(
        _ request: CompilerReferenceRequest,
        cancellation: @escaping @Sendable () -> Bool = { false }
    ) throws -> CompilerReferenceResolutionResult {
        let developerDirectory = try XcodeInstallation.validate(
            applicationPath: request.xcodeApplicationPath
        )
        let inspectedIdentity: SDKInstallationIdentity?
        if request.buildContext == nil {
            inspectedIdentity = try SDKSnapshotExtractor(runner: runner).inspectIdentity(
                xcodeApplicationPath: request.xcodeApplicationPath,
                sdkIdentifier: request.sdkIdentifier,
                timeout: min(request.timeoutPerFile, 120)
            )
        } else {
            inspectedIdentity = nil
        }
        let swiftcResult = try runner.run(
            executable: "/usr/bin/xcrun",
            arguments: ["--find", "swiftc"],
            environment: ["DEVELOPER_DIR": developerDirectory],
            workingDirectory: nil,
            timeout: min(request.timeoutPerFile, 30),
            cancellation: cancellation
        )
        guard swiftcResult.exitStatus == 0 else {
            throw SwiftDeltaError.processFailed(
                executable: "xcrun --find swiftc",
                status: swiftcResult.exitStatus,
                message: swiftcResult.safeErrorSummary
            )
        }
        let swiftc = swiftcResult.standardOutputString
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let temporaryDirectory = try TemporaryDirectory(prefix: "swiftdelta-reference-index")
        defer { temporaryDirectory.remove() }
        let moduleCache = temporaryDirectory.url.appendingPathComponent(
            "module-cache",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: moduleCache,
            withIntermediateDirectories: true
        )

        let canonicalRoot = request.projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        let buildArtifactRoot = request.buildContext?.buildArtifactRoot.map {
            URL(fileURLWithPath: $0, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
        }
        let generatedSourcePaths = Set(
            request.buildContext?.generatedSourceFiles.map {
                URL(fileURLWithPath: $0)
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
                    .path
            } ?? []
        )
        var failures: [AnalysisFailure] = []
        var sourceRecords: [String: SourceAnalysisRecord] = [:]
        var sourceByPath: [String: Data] = [:]
        for file in request.files.sorted(by: { $0.path < $1.path }) {
            if cancellation() {
                throw SwiftDeltaError.processCancelled(executable: swiftc)
            }
            do {
                let source = try readSource(
                    file,
                    inside: canonicalRoot,
                    buildArtifactRoot: buildArtifactRoot,
                    generatedSourcePaths: generatedSourcePaths
                )
                let path = file.standardizedFileURL.resolvingSymlinksInPath().path
                sourceByPath[path] = source
            } catch let error as SwiftDeltaError {
                sourceRecords[file.canonicalPath] = SourceAnalysisRecord(
                    path: file.canonicalPath,
                    disposition: .unreadable,
                    reason: error.localizedDescription
                )
                failures.append(
                    AnalysisFailure(
                        kind: .fileRead,
                        message: error.localizedDescription,
                        location: SourceLocation(path: file.path)
                    )
                )
            } catch {
                sourceRecords[file.canonicalPath] = SourceAnalysisRecord(
                    path: file.canonicalPath,
                    disposition: .unreadable,
                    reason: error.localizedDescription
                )
                failures.append(
                    AnalysisFailure(
                        kind: .parse,
                        message: error.localizedDescription,
                        location: SourceLocation(path: file.path)
                    )
                )
            }
        }

        guard !sourceByPath.isEmpty else {
            return CompilerReferenceResolutionResult(
                references: [],
                importedModules: [],
                failures: failures,
                coverage: ReferenceResolutionCoverage(
                    sdkIdentifier: request.sdkIdentifier,
                    filesRequested: request.files.count,
                    filesFailed: sourceRecords.count,
                    compilerExitStatus: nil,
                    isComplete: false,
                    sourceFiles: sourceRecords.values.sorted { $0.path < $1.path }
                )
            )
        }

        let arguments = compilerArguments(
            request: request,
            inspectedIdentity: inspectedIdentity,
            moduleCache: moduleCache,
            sourcePaths: sourceByPath.keys.sorted()
        )

        let result = try runner.run(
            executable: swiftc,
            arguments: arguments,
            environment: ["DEVELOPER_DIR": developerDirectory],
            workingDirectory: canonicalRoot,
            timeout: request.timeoutPerFile,
            cancellation: cancellation
        )
        let diagnostics = CompilerDiagnosticParser.parse(
            result.standardErrorString,
            projectRoot: canonicalRoot
        )
        // Depending on whether swiftc enters driver or frontend mode, the
        // structured AST can be written to either output stream. The parser
        // ignores non-JSON diagnostic fragments.
        var astData = result.standardOutput
        if !result.standardError.isEmpty {
            astData.append(0x0A)
            astData.append(result.standardError)
        }
        let decoded: CompilerReferenceResolutionResult?
        let parseFailure: String?
        if astData.isEmpty {
            decoded = nil
            parseFailure = nil
        } else {
            do {
                decoded = try CompilerASTReferenceParser.parse(
                    astData,
                    sources: sourceByPath
                )
                parseFailure = nil
            } catch {
                decoded = nil
                parseFailure = error.localizedDescription
            }
        }
        guard var parsed = decoded else {
            let message: String
            if let diagnostic = diagnostics.first {
                message = diagnostic.message
            } else if let parseFailure {
                let processSummary = result.safeErrorSummary
                message = processSummary.isEmpty
                    ? "The compiler AST could not be decoded: \(parseFailure)"
                    : "The compiler AST could not be decoded: \(parseFailure). "
                        + processSummary
            } else {
                message = "The compiler produced no structured AST for symbol resolution."
            }
            failures.append(
                AnalysisFailure(
                    kind: .parse,
                    message:
                        "Could not resolve SDK symbol references with the "
                        + "\(request.toolchainRole) compiler: \(message)",
                    location: nil
                )
            )
            return CompilerReferenceResolutionResult(
                references: [],
                importedModules: [],
                failures: failures,
                coverage: ReferenceResolutionCoverage(
                    sdkIdentifier: request.sdkIdentifier,
                    filesRequested: request.files.count,
                    filesFailed: sourceRecords.count + sourceByPath.count,
                    compilerExitStatus: result.exitStatus,
                    isComplete: false,
                    sourceFiles: (
                        sourceRecords.values
                            + sourceByPath.keys.map {
                                SourceAnalysisRecord(
                                    path: $0,
                                    disposition: .missingCompilerOutput,
                                    reason: message
                                )
                            }
                    ).sorted { $0.path < $1.path }
                ),
                diagnostics: diagnostics
            )
        }
        if result.exitStatus == 0,
           request.buildContext?.evidenceSource != .exactCompilerInvocation,
           request.buildContext?.compilerArguments.isEmpty != false,
           parsed.coverage.sourceFiles.contains(where: {
               $0.disposition == .missingCompilerOutput
           })
        {
            parsed = retryMissingCompilerDocuments(
                initial: parsed,
                request: request,
                swiftc: swiftc,
                developerDirectory: developerDirectory,
                projectRoot: canonicalRoot,
                moduleCache: moduleCache,
                sources: sourceByPath,
                cancellation: cancellation
            )
        }

        failures.append(contentsOf: parsed.failures)
        for record in parsed.coverage.sourceFiles {
            sourceRecords[record.path] = record
        }
        if result.exitStatus != 0 {
            failures.append(
                AnalysisFailure(
                    kind: .parse,
                    message:
                        "The \(request.toolchainRole) compiler exited with status "
                        + "\(result.exitStatus) after emitting partial reference evidence. "
                        + "The evidence is retained as incomplete and is not authoritative.",
                    location: nil
                )
            )
        }
        if request.buildContext?.isAuthoritative != true {
            failures.append(
                AnalysisFailure(
                    kind: .discovery,
                    message:
                        "Reference resolution used reconstructed compiler arguments because "
                        + "no authoritative target build context was available.",
                    location: nil
                )
            )
        }
        let context = request.buildContext
        let analysisPaths = Set(
            (context?.analysisSourceFiles ?? request.files.map(\.path))
                .map { URL(fileURLWithPath: $0).canonicalPath }
        )
        let requestedRecords = sourceRecords.values.filter {
            analysisPaths.contains(
                URL(fileURLWithPath: $0.path).canonicalPath
            )
        }.sorted { $0.path < $1.path }
        let analyzedCount = requestedRecords.count {
            $0.disposition.isSuccessful
        }
        let failedCount = requestedRecords.count {
            !$0.disposition.isSuccessful
        }
        let informationalRecords = (
            context?.excludedSourceFiles.map {
                SourceAnalysisRecord(
                    path: $0,
                    disposition: .excludedFromTarget,
                    reason: "the file is outside the selected target membership"
                )
            } ?? []
        ) + (
            context?.generatedSourceFiles.map {
                SourceAnalysisRecord(
                    path: $0,
                    disposition: .generated,
                    reason:
                        "the build identifies this generated source, but no "
                        + "compiler document was available"
                )
            } ?? []
        ) + (
            context?.nativeSourceFiles.map {
                SourceAnalysisRecord(
                    path: $0,
                    disposition: .unsupported,
                    reason:
                        "native SDK surface comparison is unavailable; only "
                        + "build diagnostics and compiler-provided Clang fix-its apply"
                )
            } ?? []
        )
        let allRecords = (requestedRecords + informationalRecords).sorted {
            $0.path < $1.path
        }
        let complete = result.exitStatus == 0
            && context?.isAuthoritative == true
            && analyzedCount == analysisPaths.count
            && failedCount == 0
            && parsed.coverage.isComplete
        let selectedMetrics = analysisPaths.compactMap {
            parsed.metricsBySource[$0]
        }
        let selectedReasons = selectedMetrics.reduce(
            into: [String: Int]()
        ) { result, metrics in
            for (reason, count) in metrics.unresolvedReasons {
                result[reason, default: 0] += count
            }
        }
        let contextualReferences = parsed.references.filter {
            analysisPaths.contains(
                URL(fileURLWithPath: $0.sourceLocation.path)
                    .canonicalPath
            )
        }.map { reference in
            SDKSymbolReference(
                preciseIdentifier: reference.preciseIdentifier,
                moduleName: reference.moduleName,
                fullyQualifiedName: reference.fullyQualifiedName,
                sourceLocation: reference.sourceLocation,
                resolutionMethod: reference.resolutionMethod,
                isActiveCompilationBranch: reference.isActiveCompilationBranch,
                target: context?.target,
                buildContextIdentity: context.map(buildContextIdentity)
            )
        }
        return CompilerReferenceResolutionResult(
            references: deduplicate(contextualReferences),
            importedModules: Array(
                Set(
                    analysisPaths.flatMap {
                        parsed.importedModulesBySource[$0] ?? []
                    }
                )
            ).sorted(),
            failures: failures,
            coverage: ReferenceResolutionCoverage(
                sdkIdentifier: request.sdkIdentifier,
                toolchainRole: request.toolchainRole,
                xcodeIdentity: context?.xcodeIdentity,
                swiftIdentity: context?.swiftIdentity,
                platform: context?.platform,
                scheme: context?.scheme,
                target: context?.target,
                configuration: context?.configuration,
                destination: context?.destination,
                architecture: context?.architecture,
                deploymentTarget: context?.deploymentTarget,
                filesRequested: analysisPaths.count,
                filesAnalyzed: analyzedCount,
                filesWithoutSDKReferences: requestedRecords.count {
                    $0.disposition == .analyzedWithoutSDKReferences
                },
                filesFailed: failedCount,
                declarationReferences: selectedMetrics.reduce(0) {
                    $0 + $1.declarationReferences
                },
                stableIdentityReferences: selectedMetrics.reduce(0) {
                    $0 + $1.stableIdentityReferences
                },
                unresolvedReferences: selectedMetrics.reduce(0) {
                    $0 + $1.unresolvedReferences
                },
                unresolvedReasons: selectedReasons,
                compilerExitStatus: result.exitStatus,
                isComplete: complete,
                sourceFiles: allRecords
            ),
            diagnostics: diagnostics.filter {
                guard let path = $0.location?.path else {
                    return true
                }
                return analysisPaths.contains(
                    URL(fileURLWithPath: path).canonicalPath
                )
            },
            importedModulesBySource: parsed.importedModulesBySource,
            metricsBySource: parsed.metricsBySource
        )
    }

    private func compilerArguments(
        request: CompilerReferenceRequest,
        inspectedIdentity: SDKInstallationIdentity?,
        moduleCache: URL,
        sourcePaths: [String]
    ) -> [String] {
        if let context = request.buildContext, !context.compilerArguments.isEmpty {
            return context.compilerArguments.map {
                $0 == "<SWIFTDELTA_MODULE_CACHE>"
                    ? moduleCache.path : $0
            }
        }
        let sdkPath = request.buildContext?.sdkPath ?? inspectedIdentity?.sdkPath ?? ""
        let moduleName = request.buildContext?.moduleName ?? "SwiftDeltaAnalyzedTarget"
        let triple: String
        if let context = request.buildContext {
            triple = targetTriple(context)
        } else {
            let sdkVersion = inspectedIdentity?.sdkVersion ?? "0"
            triple = targetTriple(
                sdkIdentifier: request.sdkIdentifier,
                sdkVersion: sdkVersion
            )
        }
        var arguments = [
            "-typecheck",
            "-parse-as-library",
            "-dump-ast",
            "-dump-ast-format", "json",
            "-j1",
            "-module-name", moduleName,
            "-sdk", sdkPath,
            "-target", triple,
            "-module-cache-path", moduleCache.path,
        ]
        if let languageVersion = request.buildContext?.swiftLanguageVersion {
            arguments.append(contentsOf: ["-swift-version", languageVersion])
        }
        for condition in request.activeCompilationConditions.sorted()
            where isValidCompilationCondition(condition)
        {
            arguments.append(contentsOf: ["-D", condition])
        }
        if let context = request.buildContext {
            arguments.append(contentsOf: context.otherSwiftFlags)
            for path in context.frameworkSearchPaths {
                arguments.append(contentsOf: ["-F", path])
            }
            for path in context.headerSearchPaths {
                arguments.append(contentsOf: ["-Xcc", "-I\(path)"])
            }
            for path in context.moduleSearchPaths {
                arguments.append(contentsOf: ["-I", path])
            }
            if let bridgingHeader = context.bridgingHeader {
                arguments.append(contentsOf: ["-import-objc-header", bridgingHeader])
            }
            if let strictConcurrency = context.strictConcurrency {
                arguments.append(contentsOf: ["-strict-concurrency=\(strictConcurrency)"])
            }
        }
        arguments.append(contentsOf: sourcePaths)
        return arguments
    }

    /// Retries a missing AST document as a primary file while retaining every
    /// other source in the target as semantic context. This path is used only
    /// for reconstructed, target-derived arguments; exact build invocations
    /// are not rewritten because doing so could discard plugin or driver state.
    private func retryMissingCompilerDocuments(
        initial: CompilerReferenceResolutionResult,
        request: CompilerReferenceRequest,
        swiftc: String,
        developerDirectory: String,
        projectRoot: URL,
        moduleCache: URL,
        sources: [String: Data],
        cancellation: @escaping @Sendable () -> Bool
    ) -> CompilerReferenceResolutionResult {
        let missingPaths = initial.coverage.sourceFiles.compactMap {
            $0.disposition == .missingCompilerOutput
                ? URL(fileURLWithPath: $0.path).canonicalPath
                : nil
        }.sorted()
        guard !missingPaths.isEmpty else {
            return initial
        }

        var references = initial.references
        var modules = Set(initial.importedModules)
        var failures = initial.failures
        var records = initial.coverage.sourceFiles.reduce(
            into: [String: SourceAnalysisRecord]()
        ) { values, record in
            let path = URL(fileURLWithPath: record.path)
                .canonicalPath
            if values[path] == nil
                || values[path]?.disposition.isSuccessful == false
            {
                values[path] = record
            }
        }
        var modulesBySource = initial.importedModulesBySource
        var metricsBySource = initial.metricsBySource
        for path in missingPaths {
            if cancellation() {
                break
            }
            guard let source = sources[path] else {
                continue
            }
            var arguments = compilerArguments(
                request: request,
                inspectedIdentity: nil,
                moduleCache: moduleCache,
                sourcePaths: []
            )
            arguments.removeAll { $0 == "-j1" }
            arguments.insert("-frontend", at: 0)
            arguments.append(contentsOf: ["-primary-file", path])
            arguments.append(
                contentsOf: sources.keys.sorted().filter { $0 != path }
            )
            do {
                let retry = try runner.run(
                    executable: swiftc,
                    arguments: arguments,
                    environment: ["DEVELOPER_DIR": developerDirectory],
                    workingDirectory: projectRoot,
                    timeout: request.timeoutPerFile,
                    cancellation: cancellation
                )
                guard retry.exitStatus == 0 else {
                    failures.append(
                        AnalysisFailure(
                            kind: .parse,
                            message:
                                "The compiler retry for \(path) exited with "
                                + "status \(retry.exitStatus); the file remains "
                                + "missing from reference coverage.",
                            location: SourceLocation(path: path)
                        )
                    )
                    continue
                }
                var retryData = retry.standardOutput
                if !retry.standardError.isEmpty {
                    retryData.append(0x0A)
                    retryData.append(retry.standardError)
                }
                let parsedRetry = try CompilerASTReferenceParser.parse(
                    retryData,
                    sources: [path: source]
                )
                guard parsedRetry.coverage.isComplete,
                      let record = parsedRetry.coverage.sourceFiles.first,
                      record.disposition.isSuccessful
                else {
                    failures.append(
                        AnalysisFailure(
                            kind: .parse,
                            message:
                                "The compiler retry did not produce one complete "
                                + "AST document for \(path).",
                            location: SourceLocation(path: path)
                        )
                    )
                    continue
                }
                failures.removeAll {
                    $0.location.map {
                        URL(fileURLWithPath: $0.path).canonicalPath
                    } == path
                        && $0.message.contains(
                            "emitted no AST document for requested source"
                        )
                }
                records[path] = record
                references.append(contentsOf: parsedRetry.references)
                modules.formUnion(parsedRetry.importedModules)
                modulesBySource[path] = parsedRetry.importedModulesBySource[path]
                    ?? parsedRetry.importedModules
                if let metrics = parsedRetry.metricsBySource[path] {
                    metricsBySource[path] = metrics
                }
                failures.append(contentsOf: parsedRetry.failures)
            } catch {
                failures.append(
                    AnalysisFailure(
                        kind: .parse,
                        message:
                            "Could not retry compiler reference output for "
                            + "\(path): \(error.localizedDescription)",
                        location: SourceLocation(path: path)
                    )
                )
            }
        }
        let sourceRecords = records.values.sorted { $0.path < $1.path }
        let analyzed = sourceRecords.count { $0.disposition.isSuccessful }
        let metrics = metricsBySource.values
        let unresolvedReasons = metrics.reduce(
            into: [String: Int]()
        ) { result, value in
            for (reason, count) in value.unresolvedReasons {
                result[reason, default: 0] += count
            }
        }
        return CompilerReferenceResolutionResult(
            references: references,
            importedModules: modules.sorted(),
            failures: failures,
            coverage: ReferenceResolutionCoverage(
                sdkIdentifier: initial.coverage.sdkIdentifier,
                filesRequested: sources.count,
                filesAnalyzed: analyzed,
                filesWithoutSDKReferences: sourceRecords.count {
                    $0.disposition == .analyzedWithoutSDKReferences
                },
                filesFailed: sourceRecords.count {
                    !$0.disposition.isSuccessful
                },
                declarationReferences: metrics.reduce(0) {
                    $0 + $1.declarationReferences
                },
                stableIdentityReferences: metrics.reduce(0) {
                    $0 + $1.stableIdentityReferences
                },
                unresolvedReferences: metrics.reduce(0) {
                    $0 + $1.unresolvedReferences
                },
                unresolvedReasons: unresolvedReasons,
                compilerExitStatus: 0,
                isComplete: analyzed == sources.count && failures.isEmpty,
                sourceFiles: sourceRecords
            ),
            importedModulesBySource: modulesBySource,
            metricsBySource: metricsBySource
        )
    }

    private func readSource(
        _ file: URL,
        inside root: URL,
        buildArtifactRoot: URL?,
        generatedSourcePaths: Set<String>
    ) throws -> Data {
        let resolved = file.standardizedFileURL.resolvingSymlinksInPath()
        let isProjectSource = resolved.isContained(in: root)
        let isCapturedGeneratedSource = buildArtifactRoot.map {
            resolved.isContained(in: $0)
                && generatedSourcePaths.contains(resolved.path)
        } ?? false
        guard isProjectSource || isCapturedGeneratedSource else {
            throw SwiftDeltaError.unsafePath(file.path)
        }
        let values = try resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw SwiftDeltaError.unsafePath(file.path)
        }
        if let size = values.fileSize, size > maximumFileSize {
            throw SwiftDeltaError.fileTooLarge(path: file.path, limit: maximumFileSize)
        }
        let handle = try FileHandle(forReadingFrom: resolved)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumFileSize + 1) ?? Data()
        guard data.count <= maximumFileSize else {
            throw SwiftDeltaError.fileTooLarge(path: file.path, limit: maximumFileSize)
        }
        guard String(data: data, encoding: .utf8) != nil else {
            throw SwiftDeltaError.invalidConfiguration(
                field: file.path,
                reason: "Swift source must use UTF-8 encoding"
            )
        }
        return data
    }

    private func targetTriple(sdkIdentifier: String, sdkVersion: String) -> String {
        let version = sdkVersion.split(separator: " ").first.map(String.init) ?? sdkVersion
        return switch sdkIdentifier.lowercased() {
        case "iphoneos": "arm64-apple-ios\(version)"
        case "iphonesimulator": "arm64-apple-ios\(version)-simulator"
        case "appletvos": "arm64-apple-tvos\(version)"
        case "appletvsimulator": "arm64-apple-tvos\(version)-simulator"
        case "watchos": "arm64-apple-watchos\(version)"
        case "watchsimulator": "arm64-apple-watchos\(version)-simulator"
        case "xros": "arm64-apple-xros\(version)"
        case "xrsimulator": "arm64-apple-xros\(version)-simulator"
        default: "arm64-apple-macosx\(version)"
        }
    }

    private func targetTriple(_ context: TargetBuildContext) -> String {
        let suffix = switch context.platformVariant?.lowercased() {
        case "simulator": "-simulator"
        case "maccatalyst", "macabi": "-macabi"
        default: ""
        }
        let operatingSystem = switch context.sdkIdentifier.lowercased() {
        case "iphoneos", "iphonesimulator": "ios"
        case "appletvos", "appletvsimulator": "tvos"
        case "watchos", "watchsimulator": "watchos"
        case "xros", "xrsimulator": "xros"
        default: "macosx"
        }
        return "\(context.architecture)-apple-\(operatingSystem)"
            + "\(context.deploymentTarget)\(suffix)"
    }

    private func isValidCompilationCondition(_ value: String) -> Bool {
        value.range(
            of: #"^[A-Za-z_][A-Za-z0-9_]*$"#,
            options: .regularExpression
        ) != nil
    }

    private func deduplicate(_ values: [SDKSymbolReference]) -> [SDKSymbolReference] {
        var selected: [String: SDKSymbolReference] = [:]
        for value in values {
            let key = [
                value.preciseIdentifier ?? "",
                value.moduleName ?? "",
                value.fullyQualifiedName ?? "",
                value.sourceLocation.path,
                value.sourceLocation.line.map(String.init) ?? "",
                value.sourceLocation.column.map(String.init) ?? "",
                value.target ?? "",
                value.buildContextIdentity ?? "",
            ].joined(separator: "|")
            selected[key] = value
        }
        return selected.values.sorted {
            let left = (
                $0.sourceLocation.path,
                $0.sourceLocation.line ?? 0,
                $0.sourceLocation.column ?? 0,
                $0.preciseIdentifier ?? ""
            )
            let right = (
                $1.sourceLocation.path,
                $1.sourceLocation.line ?? 0,
                $1.sourceLocation.column ?? 0,
                $1.preciseIdentifier ?? ""
            )
            return left < right
        }
    }

    private func buildContextIdentity(_ context: TargetBuildContext) -> String {
        [
            context.toolchainRole,
            context.xcodeIdentity ?? context.xcodeApplicationPath,
            context.sdkIdentifier,
            context.platformVariant ?? "",
            context.scheme ?? "",
            context.contextIdentity,
            context.configuration ?? "",
            context.destination ?? "",
            context.architecture,
            context.deploymentTarget,
        ].joined(separator: "|")
    }
}
