//===--- XcodeProjectBuilder.swift - SwiftDelta ------------------------------------------===//
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

/// Builds Xcode containers or pure Swift packages with isolated output paths.
///
/// The analyzed product is compiled for diagnostics but is never launched.
public struct XcodeProjectBuilder: ProjectBuilding {
    private let runner: any ProcessRunning
    private let progress: OperationProgress

    public init(
        runner: any ProcessRunning = ProcessRunner(),
        progress: OperationProgress = .silent
    ) {
        self.runner = runner
        self.progress = progress
    }

    public func build(
        _ invocation: BuildInvocation,
        cancellation: @escaping @Sendable () -> Bool
    ) throws -> BuildOutcome {
        try BuildContextSelectionValidator.validate(
            sdkIdentifiers: invocation.sdkIdentifiers,
            destination: invocation.destination
        )
        let developerDirectory = try XcodeInstallation.validate(
            applicationPath: invocation.xcodePath
        )
        let temporaryDirectory = try TemporaryDirectory(prefix: "swiftdelta-build")
        defer { temporaryDirectory.remove() }

        let derivedData = temporaryDirectory.url.appendingPathComponent(
            "DerivedData",
            isDirectory: true
        )
        let resultBundle = temporaryDirectory.url.appendingPathComponent("Build.xcresult")
        let moduleCache = temporaryDirectory.url.appendingPathComponent(
            "ModuleCache",
            isDirectory: true
        )
        let indexStore = temporaryDirectory.url.appendingPathComponent(
            "IndexStore",
            isDirectory: true
        )
        let isolatedHome = temporaryDirectory.url.appendingPathComponent(
            "Home",
            isDirectory: true
        )
        let isolatedTemporary = temporaryDirectory.url.appendingPathComponent(
            "Temporary",
            isDirectory: true
        )
        for directory in [
            derivedData, moduleCache, indexStore, isolatedHome,
            isolatedTemporary,
        ] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        if invocation.container.kind == .package {
            return try SwiftPackageBuilder(runner: runner).build(
                invocation,
                developerDirectory: developerDirectory,
                temporaryDirectory: temporaryDirectory,
                cancellation: cancellation
            )
        }

        var arguments: [String] = []
        switch invocation.container.kind {
        case .project:
            arguments.append(contentsOf: ["-project", invocation.container.path])
        case .workspace:
            arguments.append(contentsOf: ["-workspace", invocation.container.path])
        case .package:
            break
        }
        arguments.append(contentsOf: [
            "-scheme", invocation.scheme,
            "-derivedDataPath", derivedData.path,
            "-resultBundlePath", resultBundle.path,
            "-disableAutomaticPackageResolution",
            "-onlyUsePackageVersionsFromResolvedFile",
        ])
        if let configuration = invocation.configuration {
            arguments.append(contentsOf: ["-configuration", configuration])
        }
        if let destination = invocation.destination {
            arguments.append(contentsOf: ["-destination", destination])
        }
        if invocation.sdkIdentifiers.count == 1,
           let sdkIdentifier = invocation.sdkIdentifiers.first
        {
            arguments.append(contentsOf: ["-sdk", sdkIdentifier])
        }
        arguments.append(contentsOf: [
            "CLANG_MODULE_CACHE_PATH=\(moduleCache.path)",
            "SWIFT_MODULE_CACHE_PATH=\(moduleCache.path)",
            "INDEX_DATA_STORE_DIR=\(indexStore.path)",
            "CODE_SIGNING_ALLOWED=NO",
            "CODE_SIGNING_REQUIRED=NO",
            "build",
        ])

        var environment = [
            "DEVELOPER_DIR": developerDirectory,
            "HOME": isolatedHome.path,
            "CFFIXED_USER_HOME": isolatedHome.path,
            "TMPDIR": isolatedTemporary.path + "/",
            "CLANG_MODULE_CACHE_PATH": moduleCache.path,
            "SWIFTPM_MODULECACHE_OVERRIDE": moduleCache.path,
        ]
        if invocation.sdkIdentifiers.count == 1,
           let sdkIdentifier = invocation.sdkIdentifiers.first
        {
            environment["SDKROOT"] = sdkIdentifier
        }

        let result = try runner.run(
            executable: "/usr/bin/xcodebuild",
            arguments: arguments,
            environment: environment,
            workingDirectory: URL(fileURLWithPath: invocation.container.path)
                .deletingLastPathComponent(),
            timeout: invocation.timeout,
            cancellation: cancellation
        )

        // Result-bundle decoding is a bounded post-build metadata phase. If it
        // cannot complete, the existing normalized text fallback remains valid.
        let xcresult = progress.phase(
            "Reading XCResult diagnostics",
            completedMessage: "Read XCResult diagnostics"
        ) {
            XCResultReader(runner: runner).read(
                bundleURL: resultBundle,
                developerDirectory: developerDirectory,
                timeout: min(invocation.timeout, 60)
            )
        }
        let combinedLog = result.standardOutputString + "\n" + result.standardErrorString
        let textDiagnostics = CompilerDiagnosticParser.parse(
            combinedLog,
            projectRoot: URL(fileURLWithPath: invocation.container.path)
                .deletingLastPathComponent()
        )
        var diagnostics: [CompilerDiagnostic]
        let diagnosticSource: BuildDiagnosticSource
        switch xcresult.strategy {
        case .modernStructured:
            diagnostics = xcresult.diagnostics
            diagnosticSource = .modernXCResult
        case .legacyStructured:
            diagnostics = xcresult.diagnostics
            diagnosticSource = .legacyXCResult
        case .unavailable:
            diagnostics = textDiagnostics
            diagnosticSource = .xcodebuildText
        }
        if let rootCause = BuildFailureClassifier.diagnostic(
            status: result.exitStatus,
            log: combinedLog,
            invocation: invocation
        ), !diagnostics.contains(where: {
            $0.message == rootCause.message
        }) {
            diagnostics.insert(rootCause, at: 0)
        }
        if result.exitStatus != 0, diagnostics.isEmpty {
            diagnostics = [
                CompilerDiagnostic(
                    message: result.safeErrorSummary.isEmpty
                        ? "xcodebuild failed without a structured diagnostic."
                        : result.safeErrorSummary,
                    severity: .error,
                    kind: .unknown
                ),
            ]
        }

        let settings = (try? XcodeBuildSettingsProvider(runner: runner).showBuildSettings(
            container: invocation.container,
            scheme: invocation.scheme,
            configuration: invocation.configuration,
            sdkIdentifier: invocation.sdkIdentifiers.count == 1
                ? invocation.sdkIdentifiers.first
                : nil,
            destination: invocation.destination,
            developerDirectory: developerDirectory,
            derivedDataPath: derivedData,
            timeout: invocation.timeout
        )) ?? []

        return BuildOutcome(
            xcodePath: invocation.xcodePath,
            exitStatus: result.exitStatus,
            diagnostics: diagnostics,
            buildSettings: settings,
            diagnosticSource: diagnosticSource
        )
    }
}
