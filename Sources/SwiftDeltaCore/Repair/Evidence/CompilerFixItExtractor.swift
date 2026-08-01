//===--- CompilerFixItExtractor.swift - SwiftDelta ------------------------------------------===//
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

public struct CompilerFixItRequest: Sendable {
    public let files: [URL]
    public let projectRoot: URL
    public let candidateXcodePath: String
    public let sdkIdentifier: String
    public let activeCompilationConditions: [String]
    public let timeoutPerFile: TimeInterval
    public let targetBuildContexts: [TargetBuildContext]

    public init(
        files: [URL],
        projectRoot: URL,
        candidateXcodePath: String,
        sdkIdentifier: String,
        activeCompilationConditions: [String] = [],
        timeoutPerFile: TimeInterval = 60,
        targetBuildContexts: [TargetBuildContext] = []
    ) {
        self.files = files
        self.projectRoot = projectRoot
        self.candidateXcodePath = candidateXcodePath
        self.sdkIdentifier = sdkIdentifier
        self.activeCompilationConditions = activeCompilationConditions
        self.timeoutPerFile = timeoutPerFile
        self.targetBuildContexts = targetBuildContexts
    }
}

public struct CompilerFixItExtraction: Sendable {
    public let fixIts: [StructuredDiagnosticFixIt]
    public let failures: [AnalysisFailure]

    public init(
        fixIts: [StructuredDiagnosticFixIt],
        failures: [AnalysisFailure]
    ) {
        self.fixIts = fixIts
        self.failures = failures
    }
}

public struct CompilerFixItExtractor: Sendable {
    private let runner: any ProcessRunning
    private let reader: SerializedDiagnosticReader

    public init(
        runner: any ProcessRunning = ProcessRunner(),
        reader: SerializedDiagnosticReader = SerializedDiagnosticReader()
    ) {
        self.runner = runner
        self.reader = reader
    }

    public func extract(
        _ request: CompilerFixItRequest,
        cancellation: @escaping @Sendable () -> Bool = { false }
    ) throws -> CompilerFixItExtraction {
        let developerDirectory = try XcodeInstallation.validate(
            applicationPath: request.candidateXcodePath
        )
        let toolchainBin = URL(fileURLWithPath: developerDirectory)
            .appendingPathComponent("Toolchains/XcodeDefault.xctoolchain/usr/bin")
        let swiftFrontend = toolchainBin.appendingPathComponent("swift-frontend")
        let clang = toolchainBin.appendingPathComponent("clang")
        let temporaryDirectory = try TemporaryDirectory(
            prefix: "swiftdelta-repair-diagnostics"
        )
        defer { temporaryDirectory.remove() }
        let moduleCache = temporaryDirectory.url.appendingPathComponent(
            "ModuleCache",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: moduleCache,
            withIntermediateDirectories: true
        )

        var values: [StructuredDiagnosticFixIt] = []
        var failures: [AnalysisFailure] = []
        var fallbackIdentity: SDKInstallationIdentity?
        let selectedPaths = Set(
            request.files.map {
                $0.standardizedFileURL.resolvingSymlinksInPath().path
            }
        )
        var handledSwiftPaths = Set<String>()
        for (contextIndex, context) in request.targetBuildContexts.enumerated()
            where context.sdkIdentifier == request.sdkIdentifier
        {
            let selected = context.analysisSourceFiles.filter {
                selectedPaths.contains(
                    URL(fileURLWithPath: $0)
                        .standardizedFileURL.resolvingSymlinksInPath().path
                )
            }
            guard !selected.isEmpty else {
                continue
            }
            do {
                let diagnostics = temporaryDirectory.url.appendingPathComponent(
                    "target-\(contextIndex).dia"
                )
                let arguments = swiftArguments(
                    context: context,
                    moduleCache: moduleCache,
                    diagnostics: diagnostics
                )
                let process = try runner.run(
                    executable: swiftFrontend.path,
                    arguments: arguments,
                    environment: [
                        "DEVELOPER_DIR": developerDirectory,
                        "CLANG_MODULE_CACHE_PATH": moduleCache.path,
                    ],
                    workingDirectory: request.projectRoot,
                    timeout: request.timeoutPerFile,
                    cancellation: cancellation
                )
                if FileManager.default.fileExists(atPath: diagnostics.path) {
                    let decoded = try reader.read(
                        diagnosticsURL: diagnostics,
                        xcodeApplicationPath: request.candidateXcodePath
                    )
                    values.append(
                        contentsOf: decoded.filter {
                            selectedPaths.contains(
                                URL(fileURLWithPath: $0.filePath)
                                    .standardizedFileURL
                                    .resolvingSymlinksInPath().path
                            )
                        }.map {
                            attachingContext(
                                $0,
                                compilerPath: swiftFrontend.path,
                                context: context,
                                targetAware: context.isAuthoritative
                            )
                        }
                    )
                } else if process.exitStatus != 0 {
                    failures.append(
                        AnalysisFailure(
                            kind: .parse,
                            message:
                                "Target-aware compiler fix-it extraction failed "
                                + "for target \(context.target) with status "
                                + "\(process.exitStatus): \(process.safeErrorSummary)",
                            location: nil
                        )
                    )
                }
                handledSwiftPaths.formUnion(selected.map {
                    URL(fileURLWithPath: $0)
                        .standardizedFileURL.resolvingSymlinksInPath().path
                })
            } catch {
                failures.append(
                    AnalysisFailure(
                        kind: .parse,
                        message:
                            "Could not extract target-aware compiler fix-its "
                            + "for \(context.target): \(error.localizedDescription)",
                        location: nil
                    )
                )
            }
        }
        // Per-file extraction is limited to sources absent from target evidence.
        for (index, file) in request.files.sorted(by: { $0.path < $1.path }).enumerated() {
            if cancellation() {
                throw SwiftDeltaError.processCancelled(executable: "compiler fix-it extraction")
            }
            do {
                _ = try RepairSourceDocument(root: request.projectRoot, file: file)
                let diagnostics = temporaryDirectory.url.appendingPathComponent(
                    "\(index).dia"
                )
                let language = RepairPathPolicy.language(for: file)
                if language == .swift,
                   handledSwiftPaths.contains(
                    file.standardizedFileURL.resolvingSymlinksInPath().path
                   )
                {
                    continue
                }
                if fallbackIdentity == nil {
                    fallbackIdentity = try SDKSnapshotExtractor(
                        runner: runner
                    ).inspectIdentity(
                        xcodeApplicationPath: request.candidateXcodePath,
                        sdkIdentifier: request.sdkIdentifier,
                        timeout: min(request.timeoutPerFile, 120)
                    )
                }
                guard let identity = fallbackIdentity else {
                    throw RepairError.evidenceUnavailable(
                        "the candidate SDK identity could not be inspected"
                    )
                }
                let invocation: (URL, [String])
                if language == .swift {
                    guard FileManager.default.isExecutableFile(atPath: swiftFrontend.path)
                    else {
                        throw RepairError.evidenceUnavailable(
                            "the candidate Xcode does not contain swift-frontend"
                        )
                    }
                    var arguments = [
                        "-typecheck",
                        "-parse-as-library",
                        "-module-name", "SwiftDeltaRepairTarget",
                        "-sdk", identity.sdkPath,
                        "-target", targetTriple(
                            sdkIdentifier: request.sdkIdentifier,
                            sdkVersion: identity.sdkVersion
                        ),
                        "-module-cache-path", moduleCache.path,
                        "-serialize-diagnostics-path", diagnostics.path,
                    ]
                    for condition in request.activeCompilationConditions.sorted()
                        where isValidCompilationCondition(condition)
                    {
                        arguments.append(contentsOf: ["-D", condition])
                    }
                    arguments.append(file.path)
                    invocation = (swiftFrontend, arguments)
                } else {
                    guard FileManager.default.isExecutableFile(atPath: clang.path) else {
                        throw RepairError.evidenceUnavailable(
                            "the candidate Xcode does not contain clang"
                        )
                    }
                    var arguments = [
                        "-fsyntax-only",
                        "-isysroot", identity.sdkPath,
                        "-fmodules-cache-path=\(moduleCache.path)",
                        "-serialize-diagnostics", diagnostics.path,
                    ]
                    if language == .cOrObjectiveCHeader {
                        arguments.append(contentsOf: ["-x", "objective-c-header"])
                    } else if language == .cppOrObjectiveCppHeader {
                        arguments.append(
                            contentsOf: ["-x", "objective-c++-header"]
                        )
                    }
                    arguments.append(file.path)
                    invocation = (clang, arguments)
                }
                _ = try runner.run(
                    executable: invocation.0.path,
                    arguments: invocation.1,
                    environment: [
                        "DEVELOPER_DIR": developerDirectory,
                        "CLANG_MODULE_CACHE_PATH": moduleCache.path,
                    ],
                    workingDirectory: request.projectRoot,
                    timeout: request.timeoutPerFile,
                    cancellation: cancellation
                )
                if FileManager.default.fileExists(atPath: diagnostics.path) {
                    values.append(
                        contentsOf: try reader.read(
                            diagnosticsURL: diagnostics,
                            xcodeApplicationPath: request.candidateXcodePath
                        ).map {
                            attachingFallbackContext(
                                $0,
                                compilerPath: invocation.0.path,
                                identity: identity
                            )
                        }
                    )
                }
            } catch {
                failures.append(
                    AnalysisFailure(
                        kind: .parse,
                        message: "Could not extract structured compiler fix-its: \(error.localizedDescription)",
                        location: SourceLocation(path: file.path)
                    )
                )
            }
        }
        return CompilerFixItExtraction(
            fixIts: values.sorted(by: {
                (
                    $0.filePath,
                    $0.sourceRange.start.utf8Offset,
                    $0.sourceRange.end.utf8Offset,
                    $0.replacementText
                ) < (
                    $1.filePath,
                    $1.sourceRange.start.utf8Offset,
                    $1.sourceRange.end.utf8Offset,
                    $1.replacementText
                )
            }),
            failures: failures
        )
    }

    private func swiftArguments(
        context: TargetBuildContext,
        moduleCache: URL,
        diagnostics: URL
    ) -> [String] {
        var arguments = [
            "-typecheck",
            "-parse-as-library",
            "-module-name", context.moduleName,
            "-sdk", context.sdkPath,
            "-target", targetTriple(context),
            "-module-cache-path", moduleCache.path,
            "-serialize-diagnostics-path", diagnostics.path,
        ]
        if let languageVersion = context.swiftLanguageVersion {
            arguments.append(contentsOf: ["-swift-version", languageVersion])
        }
        for condition in context.activeCompilationConditions.sorted()
            where isValidCompilationCondition(condition)
        {
            arguments.append(contentsOf: ["-D", condition])
        }
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
            arguments.append("-strict-concurrency=\(strictConcurrency)")
        }
        arguments.append(contentsOf: context.sourceFiles)
        return arguments
    }

    private func attachingContext(
        _ fixIt: StructuredDiagnosticFixIt,
        compilerPath: String,
        context: TargetBuildContext,
        targetAware: Bool
    ) -> StructuredDiagnosticFixIt {
        StructuredDiagnosticFixIt(
            filePath: fixIt.filePath,
            sourceRange: fixIt.sourceRange,
            replacementText: fixIt.replacementText,
            diagnosticText: fixIt.diagnosticText,
            diagnosticSeverity: fixIt.diagnosticSeverity,
            diagnosticIndex: fixIt.diagnosticIndex,
            fixItIndex: fixIt.fixItIndex,
            compilerContext: RepairCompilerContextEvidence(
                compilerPath: compilerPath,
                target: context.target,
                moduleName: context.moduleName,
                sdkIdentifier: context.sdkIdentifier,
                sdkPath: context.sdkPath,
                destination: context.destination,
                diagnosticIdentity: diagnosticIdentity(fixIt),
                evidenceArtifact: "serializedDiagnostics",
                isTargetAware: targetAware
            )
        )
    }

    private func attachingFallbackContext(
        _ fixIt: StructuredDiagnosticFixIt,
        compilerPath: String,
        identity: SDKInstallationIdentity
    ) -> StructuredDiagnosticFixIt {
        StructuredDiagnosticFixIt(
            filePath: fixIt.filePath,
            sourceRange: fixIt.sourceRange,
            replacementText: fixIt.replacementText,
            diagnosticText: fixIt.diagnosticText,
            diagnosticSeverity: fixIt.diagnosticSeverity,
            diagnosticIndex: fixIt.diagnosticIndex,
            fixItIndex: fixIt.fixItIndex,
            compilerContext: RepairCompilerContextEvidence(
                compilerPath: compilerPath,
                sdkIdentifier: identity.sdkIdentifier,
                sdkPath: identity.sdkPath,
                diagnosticIdentity: diagnosticIdentity(fixIt),
                evidenceArtifact: "serializedDiagnosticsFallback",
                isTargetAware: false
            )
        )
    }

    private func diagnosticIdentity(
        _ fixIt: StructuredDiagnosticFixIt
    ) -> String {
        RepairFingerprint.identifier([
            fixIt.filePath,
            fixIt.diagnosticText,
            String(fixIt.diagnosticIndex),
            String(fixIt.sourceRange.start.utf8Offset),
            String(fixIt.sourceRange.end.utf8Offset),
        ])
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
        let operatingSystem = switch context.sdkIdentifier.lowercased() {
        case "iphoneos", "iphonesimulator": "ios"
        case "appletvos", "appletvsimulator": "tvos"
        case "watchos", "watchsimulator": "watchos"
        case "xros", "xrsimulator": "xros"
        default: "macosx"
        }
        let suffix = switch context.platformVariant?.lowercased() {
        case "simulator": "-simulator"
        case "maccatalyst", "macabi": "-macabi"
        default: ""
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
}
