//===--- SwiftPackageBuilder.swift - SwiftDelta ------------------------------------------===//
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

struct SwiftPackageBuilder: Sendable {
    private let runner: any ProcessRunning

    init(runner: any ProcessRunning) {
        self.runner = runner
    }

    func build(
        _ invocation: BuildInvocation,
        developerDirectory: String,
        temporaryDirectory: TemporaryDirectory,
        cancellation: @escaping @Sendable () -> Bool
    ) throws -> BuildOutcome {
        let manifest = URL(fileURLWithPath: invocation.container.path).canonicalFileURL
        guard manifest.lastPathComponent == "Package.swift",
              FileManager.default.fileExists(atPath: manifest.path)
        else {
            throw SwiftDeltaError.invalidConfiguration(
                field: "container",
                reason: "a package container must point to Package.swift"
            )
        }
        let packageRoot = manifest.deletingLastPathComponent()
        let swift = URL(fileURLWithPath: developerDirectory)
            .appendingPathComponent(
                "Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
            )
        guard FileManager.default.isExecutableFile(atPath: swift.path) else {
            throw SwiftDeltaError.processLaunch(
                executable: swift.path,
                reason: "the selected Xcode does not contain an executable Swift driver"
            )
        }

        let scratch = temporaryDirectory.url.appendingPathComponent(
            "Scratch",
            isDirectory: true
        )
        let cache = temporaryDirectory.url.appendingPathComponent("Cache", isDirectory: true)
        let configuration = temporaryDirectory.url.appendingPathComponent(
            "Configuration",
            isDirectory: true
        )
        let security = temporaryDirectory.url.appendingPathComponent("Security", isDirectory: true)
        let home = temporaryDirectory.url.appendingPathComponent("Home", isDirectory: true)
        let processTemporary = temporaryDirectory.url.appendingPathComponent(
            "Temporary",
            isDirectory: true
        )
        let moduleCache = scratch.appendingPathComponent(
            "ModuleCache",
            isDirectory: true
        )
        for directory in [
            scratch, cache, configuration, security, home, processTemporary,
            moduleCache,
        ] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        // The package and its lock file remain read-only. Locked repositories
        // are copied from an existing local cache into the isolated cache.
        try SwiftPackageDependencyCacheSeeder.seed(
            packageRoot: packageRoot,
            isolatedCache: cache
        )

        var arguments = [
            "build",
            "--package-path", packageRoot.path,
            "--scratch-path", scratch.path,
            "--cache-path", cache.path,
            "--config-path", configuration.path,
            "--security-path", security.path,
            "--disable-automatic-resolution",
            "--disable-experimental-prebuilts",
            "--disable-prefetching",
            "--skip-update",
            "--manifest-cache", "none",
        ]
        if let buildConfiguration = invocation.configuration?.lowercased() {
            arguments.append(contentsOf: ["--configuration", buildConfiguration])
        }
        if let sdkIdentifier = invocation.sdkIdentifiers.first,
           sdkIdentifier.lowercased() != "macosx"
        {
            let identity = try SDKSnapshotExtractor(runner: runner).inspectIdentity(
                xcodeApplicationPath: invocation.xcodePath,
                sdkIdentifier: sdkIdentifier,
                timeout: min(invocation.timeout, 120)
            )
            let deploymentTarget = try packageDeploymentTarget(
                swift: swift,
                packageRoot: packageRoot,
                sdkIdentifier: sdkIdentifier,
                developerDirectory: developerDirectory,
                scratch: scratch,
                cache: cache,
                configuration: configuration,
                security: security,
                home: home,
                processTemporary: processTemporary,
                moduleCache: moduleCache,
                timeout: invocation.timeout,
                cancellation: cancellation
            )
            arguments.append(contentsOf: [
                "--sdk", identity.sdkPath,
                "--triple", targetTriple(
                    sdkIdentifier: sdkIdentifier,
                    deploymentTarget: deploymentTarget,
                    destination: invocation.destination
                ),
            ])
        }
        arguments.append(contentsOf: [
            "-Xswiftc", "-module-cache-path",
            "-Xswiftc", moduleCache.path,
        ])

        let result = try runner.run(
            executable: swift.path,
            arguments: arguments,
            environment: isolatedEnvironment(
                developerDirectory: developerDirectory,
                home: home,
                temporary: processTemporary,
                moduleCache: moduleCache,
                sdkIdentifier: invocation.sdkIdentifiers.first
            ),
            workingDirectory: packageRoot,
            timeout: invocation.timeout,
            cancellation: cancellation
        )
        let combinedLog = result.standardOutputString + "\n" + result.standardErrorString
        if result.exitStatus != 0, let blocker = offlineDependencyBlocker(in: combinedLog) {
            throw SwiftDeltaError.offlineDependencyUnavailable(blocker)
        }
        var diagnostics = CompilerDiagnosticParser.parse(
            combinedLog,
            projectRoot: packageRoot
        )
        if result.exitStatus != 0, diagnostics.isEmpty {
            diagnostics = [
                CompilerDiagnostic(
                    message: result.safeErrorSummary.isEmpty
                        ? "swift build failed without a compiler diagnostic."
                        : result.safeErrorSummary,
                    severity: .error,
                    kind: .package
                ),
            ]
        }
        return BuildOutcome(
            xcodePath: invocation.xcodePath,
            exitStatus: result.exitStatus,
            diagnostics: diagnostics,
            buildSettings: [],
            diagnosticSource: .swiftBuildText
        )
    }

    private func packageDeploymentTarget(
        swift: URL,
        packageRoot: URL,
        sdkIdentifier: String,
        developerDirectory: String,
        scratch: URL,
        cache: URL,
        configuration: URL,
        security: URL,
        home: URL,
        processTemporary: URL,
        moduleCache: URL,
        timeout: TimeInterval,
        cancellation: @escaping @Sendable () -> Bool
    ) throws -> String {
        let result = try runner.run(
            executable: swift.path,
            arguments: [
                "package",
                "--package-path", packageRoot.path,
                "--scratch-path", scratch.appendingPathComponent("description").path,
                "--cache-path", cache.path,
                "--config-path", configuration.path,
                "--security-path", security.path,
                "--disable-automatic-resolution",
                "--disable-prefetching",
                "--skip-update",
                "describe",
                "--type", "json",
            ],
            environment: isolatedEnvironment(
                developerDirectory: developerDirectory,
                home: home,
                temporary: processTemporary,
                moduleCache: moduleCache,
                sdkIdentifier: sdkIdentifier
            ),
            workingDirectory: packageRoot,
            timeout: timeout,
            cancellation: cancellation
        )
        guard result.exitStatus == 0 else {
            throw SwiftDeltaError.processFailed(
                executable: "swift package describe",
                status: result.exitStatus,
                message:
                    "the selected toolchain could not interpret the package "
                    + "manifest: \(result.safeErrorSummary)"
            )
        }
        guard let object = try JSONSerialization.jsonObject(
            with: result.standardOutput
        ) as? [String: Any],
            let platforms = object["platforms"] as? [[String: Any]]
        else {
            throw SwiftDeltaError.invalidConfiguration(
                field: "Package.swift",
                reason:
                    "the selected toolchain did not return structured package "
                    + "platform metadata"
            )
        }
        let expected = packagePlatformName(sdkIdentifier)
        guard let version = platforms.first(where: {
            ($0["name"] as? String)?.lowercased() == expected
        })?["version"] as? String,
            !version.isEmpty
        else {
            throw SwiftDeltaError.invalidConfiguration(
                field: "Package.swift",
                reason:
                    "a \(expected) deployment version is required for an "
                    + "\(sdkIdentifier) Swift Package comparison"
            )
        }
        return version
    }

    private func isolatedEnvironment(
        developerDirectory: String,
        home: URL,
        temporary: URL,
        moduleCache: URL,
        sdkIdentifier: String?
    ) -> [String: String] {
        var values = [
            "DEVELOPER_DIR": developerDirectory,
            "HOME": home.path,
            "CFFIXED_USER_HOME": home.path,
            "TMPDIR": temporary.path + "/",
            "CLANG_MODULE_CACHE_PATH": moduleCache.path,
            "SWIFTPM_MODULECACHE_OVERRIDE": moduleCache.path,
        ]
        if let sdkIdentifier, !sdkIdentifier.isEmpty {
            values["SDKROOT"] = sdkIdentifier
        }
        return values
    }

    private func packagePlatformName(_ sdkIdentifier: String) -> String {
        switch sdkIdentifier.lowercased() {
        case "iphoneos", "iphonesimulator": "ios"
        case "appletvos", "appletvsimulator": "tvos"
        case "watchos", "watchsimulator": "watchos"
        case "xros", "xrsimulator": "visionos"
        default: "macos"
        }
    }

    private func targetTriple(
        sdkIdentifier: String,
        deploymentTarget: String,
        destination: String?
    ) -> String {
        let lowerDestination = destination?.lowercased() ?? ""
        let architecture = lowerDestination.contains("arch=x86_64")
            ? "x86_64"
            : "arm64"
        return switch sdkIdentifier.lowercased() {
        case "iphoneos":
            "\(architecture)-apple-ios\(deploymentTarget)"
        case "iphonesimulator":
            "\(architecture)-apple-ios\(deploymentTarget)-simulator"
        case "appletvos":
            "\(architecture)-apple-tvos\(deploymentTarget)"
        case "appletvsimulator":
            "\(architecture)-apple-tvos\(deploymentTarget)-simulator"
        case "watchos":
            "\(architecture)-apple-watchos\(deploymentTarget)"
        case "watchsimulator":
            "\(architecture)-apple-watchos\(deploymentTarget)-simulator"
        case "xros":
            "\(architecture)-apple-xros\(deploymentTarget)"
        case "xrsimulator":
            "\(architecture)-apple-xros\(deploymentTarget)-simulator"
        default:
            "\(architecture)-apple-macosx\(deploymentTarget)"
        }
    }

    private func offlineDependencyBlocker(in text: String) -> String? {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        let markers = [
            "not found in local cache",
            "could not resolve dependencies",
            "couldn’t fetch",
            "couldn't fetch",
            "failed to clone",
            "network connection",
            "disable-automatic-resolution",
            "resolved file is required",
        ]
        return lines.first { line in
            let lower = line.lowercased()
            return markers.contains { lower.contains($0) }
        }.map(SecretRedactor.redact)
    }
}
