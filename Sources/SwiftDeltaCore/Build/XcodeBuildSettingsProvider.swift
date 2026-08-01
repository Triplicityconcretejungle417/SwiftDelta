//===--- XcodeBuildSettingsProvider.swift - SwiftDelta ------------------------------------------===//
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

public struct XcodeBuildSettingsProvider: Sendable {
    private let runner: any ProcessRunning

    public init(runner: any ProcessRunning = ProcessRunner()) {
        self.runner = runner
    }

    public func showBuildSettings(
        container: ProjectContainer,
        scheme: String,
        configuration: String? = nil,
        sdkIdentifier: String? = nil,
        destination: String? = nil,
        developerDirectory: String? = nil,
        derivedDataPath: URL? = nil,
        timeout: TimeInterval = 60
    ) throws -> [BuildSettingsSnapshot] {
        let temporaryDirectory: TemporaryDirectory?
        let effectiveDerivedDataPath: URL
        if let derivedDataPath {
            temporaryDirectory = nil
            effectiveDerivedDataPath = derivedDataPath
        } else {
            let directory = try TemporaryDirectory(
                prefix: "swiftdelta-build-settings"
            )
            temporaryDirectory = directory
            effectiveDerivedDataPath = directory.url.appendingPathComponent(
                "DerivedData",
                isDirectory: true
            )
        }
        defer { temporaryDirectory?.remove() }
        try FileManager.default.createDirectory(
            at: effectiveDerivedDataPath,
            withIntermediateDirectories: true
        )
        let isolationRoot = effectiveDerivedDataPath.appendingPathComponent(
            "SwiftDeltaInspection",
            isDirectory: true
        )
        let home = isolationRoot.appendingPathComponent("Home", isDirectory: true)
        let temporary = isolationRoot.appendingPathComponent(
            "Temporary",
            isDirectory: true
        )
        let moduleCache = isolationRoot.appendingPathComponent(
            "ModuleCache",
            isDirectory: true
        )
        for directory in [home, temporary, moduleCache] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        var arguments: [String] = []
        switch container.kind {
        case .project:
            arguments.append(contentsOf: ["-project", container.path])
        case .workspace:
            arguments.append(contentsOf: ["-workspace", container.path])
        case .package:
            throw SwiftDeltaError.invalidConfiguration(
                field: "container",
                reason: "effective Xcode build settings require a project or workspace"
            )
        }
        arguments.append(contentsOf: [
            "-scheme", scheme,
            "-derivedDataPath", effectiveDerivedDataPath.path,
            "-showBuildSettings",
            "-json",
            "-disableAutomaticPackageResolution",
            "-onlyUsePackageVersionsFromResolvedFile",
        ])
        if let configuration {
            arguments.append(contentsOf: ["-configuration", configuration])
        }
        if let sdkIdentifier {
            arguments.append(contentsOf: ["-sdk", sdkIdentifier])
        }
        if let destination {
            arguments.append(contentsOf: ["-destination", destination])
        }

        var environment = [
            "HOME": home.path,
            "CFFIXED_USER_HOME": home.path,
            "TMPDIR": temporary.path + "/",
            "CLANG_MODULE_CACHE_PATH": moduleCache.path,
            "SWIFTPM_MODULECACHE_OVERRIDE": moduleCache.path,
        ]
        if let developerDirectory {
            environment["DEVELOPER_DIR"] = developerDirectory
        }
        if let sdkIdentifier {
            environment["SDKROOT"] = sdkIdentifier
        }

        let result = try runner.run(
            executable: "/usr/bin/xcodebuild",
            arguments: arguments,
            environment: environment,
            workingDirectory: URL(fileURLWithPath: container.path).deletingLastPathComponent(),
            timeout: timeout,
            cancellation: { false }
        )
        guard result.exitStatus == 0 else {
            throw SwiftDeltaError.processFailed(
                executable: "xcodebuild -showBuildSettings",
                status: result.exitStatus,
                message: result.safeErrorSummary
            )
        }
        return try BuildSettingsParser.parse(
            result.standardOutput,
            fallbackConfiguration: configuration
        )
    }
}
