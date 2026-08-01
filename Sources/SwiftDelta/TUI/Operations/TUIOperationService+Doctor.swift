//===--- TUIOperationService+Doctor.swift - SwiftDelta ------------------------------------------===//
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
    func doctor(
        root: URL,
        workflow: TUIWorkflowSettings,
        runner: any ProcessRunning,
        progress: OperationProgress,
        cancellation: @escaping @Sendable () -> Bool
    ) throws -> TUIDoctorResult {
        let configuration = try effectiveConfiguration(
            root: root,
            workflow: workflow
        )
        let discovery = try progress.phase(
            "Discovering project",
            completedMessage: "Discovered project"
        ) {
            try ProjectDiscovery().discover(
                root: root,
                excludedPaths: configuration.excludedPaths
            )
        }
        let container = try ProjectDiscovery().selectBuildContainer(
            from: discovery,
            project: configuration.defaultProject,
            workspace: configuration.defaultWorkspace
        )
        var lines = [
            "Project root: \(discovery.root)",
            "Swift files discovered: \(discovery.swiftFiles.count)",
            "Containers: \(discovery.containers.count)",
            "Selected container: \(container.kind.rawValue) \(container.path)",
        ]
        var issues: [String] = []
        var notes: [String] = []
        do {
            let dependencies = try SwiftPackageDependencyCacheInspector.inspect(
                container: container
            )
            if dependencies.dependencyCount > 0 {
                lines.append(
                    "Local SwiftPM dependencies: "
                        + "\(dependencies.dependencyCount - dependencies.missingDependencies.count)/"
                        + "\(dependencies.dependencyCount) cached"
                )
            }
            if !dependencies.missingDependencies.isEmpty {
                issues.append(
                    "Offline SwiftPM dependencies are missing from local caches: "
                        + dependencies.missingDependencies.joined(separator: ", ")
                )
            }
        } catch {
            issues.append(
                "Local dependency inspection failed: \(error.localizedDescription)"
            )
        }
        for risk in buildExecutionRisks(discovery: discovery) {
            notes.append(risk)
        }
        let cacheRoot = SDKCacheManager().root
        if let writable = nearestExistingAncestor(of: cacheRoot),
           FileManager.default.isWritableFile(atPath: writable.path)
        {
            lines.append("SDK cache location is writable: \(writable.path)")
        } else {
            issues.append(
                "SwiftDelta's SDK cache location is not writable: \(cacheRoot.path)"
            )
        }
        let temporaryRoot = FileManager.default.temporaryDirectory
            .standardizedFileURL.resolvingSymlinksInPath()
        if FileManager.default.isWritableFile(atPath: temporaryRoot.path) {
            lines.append("Temporary workspace is writable: \(temporaryRoot.path)")
        } else {
            issues.append(
                "The temporary workspace is not writable: \(temporaryRoot.path)"
            )
        }
        let selections: [(String, String?)] = [
            ("Baseline", workflow.baselineXcodePath),
            ("Candidate", workflow.candidateXcodePath),
        ]
        var installations: [(role: String, path: String, developer: String)] = []
        for (role, path) in selections {
            guard let path else {
                issues.append("\(role) Xcode is not selected.")
                continue
            }
            do {
                let developer = try XcodeInstallation.validate(
                    applicationPath: path
                )
                let trust = try XcodeInstallation.inspectTrust(
                    applicationPath: path,
                    runner: runner,
                    timeout: min(workflow.doctorTimeout, 30)
                )
                lines.append(
                    "\(role) signature: \(trust.bundleIdentifier), team "
                        + "\(trust.teamIdentifier ?? "unavailable")"
                )
                switch trust.state {
                case .trusted:
                    lines.append("\(role) trust: Apple signature verified")
                case .appleSignedTrustUnavailable:
                    notes.append("\(role) trust: \(trust.detail)")
                case .invalid:
                    issues.append("\(role) Xcode trust: \(trust.detail)")
                    continue
                }
                let environment = EnvironmentInspector(runner: runner).inspect(
                    developerDirectory: developer,
                    timeout: min(workflow.doctorTimeout, 30)
                )
                lines.append(
                    "\(role) Xcode: \(condensed(environment.xcodeVersion) ?? "unavailable")"
                )
                lines.append(
                    "\(role) Swift: \(condensed(environment.swiftVersion) ?? "unavailable")"
                )
                let tools = try inspectTools(
                    developerDirectory: developer,
                    runner: runner,
                    timeout: workflow.doctorTimeout,
                    cancellation: cancellation
                )
                lines.append(
                    "\(role) tools: "
                        + tools.sorted().joined(separator: ", ")
                )
                if tools.contains(where: { $0.hasSuffix("=missing") }) {
                    issues.append(
                        "\(role) Xcode is missing one or more required command-line tools."
                    )
                    continue
                }
                let xcresultVersion = try runner.run(
                    executable: "/usr/bin/xcrun",
                    arguments: ["xcresulttool", "version"],
                    environment: ["DEVELOPER_DIR": developer],
                    workingDirectory: nil,
                    timeout: min(workflow.doctorTimeout, 30),
                    cancellation: cancellation
                )
                if xcresultVersion.exitStatus == 0 {
                    lines.append(
                        "\(role) xcresulttool: "
                            + xcresultVersion.standardOutputString
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                } else {
                    issues.append(
                        "\(role) xcresulttool capability inspection failed: "
                            + xcresultVersion.safeErrorSummary
                    )
                    continue
                }
                installations.append((role, path, developer))
            } catch {
                issues.append("\(role): \(error.localizedDescription)")
            }
        }
        var sdkIdentifiers = configuration.sdkIdentifiers
        var sdkSelectionIsAmbiguous = false
        if sdkIdentifiers.isEmpty, let installation = installations.last {
            do {
                sdkIdentifiers = try inferredSDKIdentifiers(
                    discovery: discovery,
                    container: container,
                    configuration: configuration,
                    developerDirectory: installation.developer,
                    workflow: workflow,
                    runner: runner
                )
                if sdkIdentifiers.count > 1 {
                    sdkSelectionIsAmbiguous = true
                    lines.append(
                        "Available SDK contexts: "
                            + sdkIdentifiers.joined(separator: ", ")
                    )
                    issues.append(
                        "Several material platform contexts remain equally suitable. "
                            + "Choose one under Customize Setup: "
                            + sdkIdentifiers.joined(separator: ", ")
                    )
                    sdkIdentifiers = []
                }
            } catch {
                issues.append(
                    "SDK inference with \(installation.role) Xcode failed: "
                        + error.localizedDescription
                )
            }
        }
        if sdkIdentifiers.isEmpty {
            if !sdkSelectionIsAmbiguous {
                issues.append(
                    "No SDK was selected or inferred from the effective build context."
                )
            }
        } else {
            lines.append(
                "SDK selection: \(sdkIdentifiers.joined(separator: ", "))"
            )
            do {
                try BuildContextSelectionValidator.validate(
                    sdkIdentifiers: sdkIdentifiers,
                    destination: workflow.destination
                )
            } catch {
                issues.append(error.localizedDescription)
            }
        }
        if let destination = workflow.destination {
            lines.append("Destination: \(destination)")
        }
        for installation in installations {
            for sdkIdentifier in sdkIdentifiers {
                do {
                    let resolution = try progress.phase(
                        "Inspecting \(installation.role.lowercased()) "
                            + "\(sdkIdentifier) build context",
                        completedMessage:
                            "Inspected \(installation.role.lowercased()) "
                            + "\(sdkIdentifier) build context"
                    ) {
                        try TargetBuildContextProvider(runner: runner).resolve(
                            discovery: discovery,
                            configuration: configuration,
                            xcodeApplicationPath: installation.path,
                            toolchainRole: installation.role.lowercased(),
                            sdkIdentifier: sdkIdentifier,
                            buildConfiguration: workflow.buildConfiguration,
                            destination: workflow.destination,
                            timeout: workflow.doctorTimeout,
                            captureExactCompilerInvocations: false
                        )
                    }
                    append(
                        resolution,
                        role: installation.role,
                        sdkIdentifier: sdkIdentifier,
                        to: &lines,
                        issues: &issues,
                        notes: &notes
                    )
                } catch {
                    issues.append(
                        "\(installation.role) \(sdkIdentifier) context: "
                            + error.localizedDescription
                    )
                }
            }
        }
        let cache = try SDKCacheManager().status()
        lines.append(
            "SDK cache: \(cache.entryCount) entries, "
                + "\(cache.byteCount) bytes"
        )
        return TUIDoctorResult(lines: lines, issues: issues, notes: notes)
    }

    func inspectTools(
        developerDirectory: String,
        runner: any ProcessRunning,
        timeout: TimeInterval,
        cancellation: @escaping @Sendable () -> Bool
    ) throws -> [String] {
        try ["swiftc", "clang", "xcresulttool", "swift-symbolgraph-extract"].map {
            let result = try runner.run(
                executable: "/usr/bin/xcrun",
                arguments: ["--find", $0],
                environment: ["DEVELOPER_DIR": developerDirectory],
                workingDirectory: nil,
                timeout: timeout,
                cancellation: cancellation
            )
            return "\($0)=\(result.exitStatus == 0 ? "available" : "missing")"
        }
    }

    private func inferredSDKIdentifiers(
        discovery: DiscoveryResult,
        container: ProjectContainer,
        configuration: SwiftDeltaConfiguration,
        developerDirectory: String,
        workflow: TUIWorkflowSettings,
        runner: any ProcessRunning
    ) throws -> [String] {
        if container.kind == .package {
            let result = try PackageAnalyzer().analyze(
                manifestURL: URL(fileURLWithPath: container.path)
            )
            let identifiers = result.metadata.minimumPlatforms.keys.compactMap {
                switch $0.lowercased() {
                case "ios": "iphoneos"
                case "macos": "macosx"
                case "tvos": "appletvos"
                case "watchos": "watchos"
                case "visionos": "xros"
                default: nil
                }
            }
            return identifiers.isEmpty ? ["macosx"] : Array(Set(identifiers)).sorted()
        }

        let details = try XcodeContainerInspector(runner: runner).inspect(
            container,
            developerDirectory: developerDirectory,
            timeout: min(workflow.doctorTimeout, 30)
        )
        let scheme = try ScanEngine().selectScheme(
            configured: configuration.defaultScheme,
            available: details.schemes
        )
        let snapshots = try XcodeBuildSettingsProvider(
            runner: runner
        ).showBuildSettings(
            container: container,
            scheme: scheme,
            configuration: workflow.buildConfiguration,
            destination: workflow.destination,
            developerDirectory: developerDirectory,
            timeout: workflow.doctorTimeout
        )
        if let preferred = TUIAutomaticSetupSelector()
            .preferredSDKContext(from: snapshots)
        {
            return [preferred.identifier]
        }
        return BuildSettingsAnalyzer().sdkIdentifiers(in: snapshots)
    }

    private func append(
        _ resolution: TargetBuildContextResolution,
        role: String,
        sdkIdentifier: String,
        to lines: inout [String],
        issues: inout [String],
        notes: inout [String]
    ) {
        if let identity = resolution.sdkIdentity {
            lines.append(
                "\(role) \(sdkIdentifier): SDK \(identity.sdkVersion), "
                    + "\(identity.platform), Xcode \(identity.xcodeVersion) "
                    + "(\(identity.xcodeBuild))"
            )
        }
        for context in resolution.contexts {
            let scheme = context.scheme ?? "Swift Package"
            let configuration = context.configuration ?? "default"
            let variant = context.platformVariant.map { "/\($0)" } ?? ""
            lines.append(
                "\(role) target \(context.target): scheme \(scheme), "
                    + "configuration \(configuration), "
                    + "\(context.platform)\(variant), "
                    + "deployment \(context.deploymentTarget), "
                    + "architecture \(context.architecture), "
                    + "\(context.analysisSourceFiles.count)/"
                    + "\(context.sourceFiles.count) source files"
            )
            if !context.generatedSourceFiles.isEmpty {
                lines.append(
                    "\(role) target \(context.target): "
                        + "\(context.generatedSourceFiles.count) generated source file(s)"
                )
            }
            if !context.nativeSourceFiles.isEmpty {
                lines.append(
                    "\(role) target \(context.target): "
                        + "\(context.nativeSourceFiles.count) native source file(s)"
                )
            }
            if !context.isAuthoritative {
                if context.evidenceSource == .xcodeBuildSettings
                    || context.evidenceSource == .swiftPackageDescription
                {
                    lines.append(
                        "\(role) target \(context.target): exact compiler "
                            + "context will be captured by the compatibility check"
                    )
                } else {
                    issues.append(
                        "\(role) target \(context.target) build context is incomplete."
                    )
                }
            }
        }
        if !resolution.excludedSourceFiles.isEmpty {
            lines.append(
                "\(role) \(sdkIdentifier): "
                    + "\(resolution.excludedSourceFiles.count) discovered Swift "
                    + "file(s) are outside the selected targets"
            )
        }
        let deferred = Set(resolution.preflightDeferredFailures)
        for failure in resolution.failures {
            let message = "\(role) \(sdkIdentifier): \(failure.message)"
            if deferred.contains(failure) {
                notes.append(message)
            } else {
                issues.append(message)
            }
        }
        if resolution.contexts.isEmpty,
           resolution.preflightDeferredFailures.isEmpty
        {
            issues.append(
                "\(role) \(sdkIdentifier): no target build context was resolved."
            )
        }
    }

    private func buildExecutionRisks(
        discovery: DiscoveryResult
    ) -> [String] {
        var values: [String] = []
        for container in discovery.containers {
            switch container.kind {
            case .project:
                let projectFile = URL(fileURLWithPath: container.path)
                    .appendingPathComponent("project.pbxproj")
                guard let source = try? String(
                    contentsOf: projectFile,
                    encoding: .utf8
                ) else { continue }
                let scripts = source.components(
                    separatedBy: "isa = PBXShellScriptBuildPhase;"
                ).count - 1
                let rules = source.components(
                    separatedBy: "isa = PBXBuildRule;"
                ).count - 1
                if scripts > 0 || rules > 0 {
                    values.append(
                        "\(URL(fileURLWithPath: container.path).lastPathComponent) "
                            + "declares \(scripts) shell-script phase(s) and "
                            + "\(rules) custom build rule(s) that may execute during comparison."
                    )
                }
            case .package:
                guard let source = try? String(
                    contentsOfFile: container.path,
                    encoding: .utf8
                ) else { continue }
                var features: [String] = []
                if source.contains(".plugin(") { features.append("plugins") }
                if source.contains(".macro(") { features.append("macros") }
                if !features.isEmpty {
                    values.append(
                        "Package.swift declares \(features.joined(separator: " and ")) "
                            + "that may load local executable code during comparison."
                    )
                }
            case .workspace:
                continue
            }
        }
        return values.sorted()
    }

    private func nearestExistingAncestor(of url: URL) -> URL? {
        var candidate = url.standardizedFileURL
        while candidate.path != "/" {
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        return FileManager.default.fileExists(atPath: "/") ? candidate : nil
    }

}
