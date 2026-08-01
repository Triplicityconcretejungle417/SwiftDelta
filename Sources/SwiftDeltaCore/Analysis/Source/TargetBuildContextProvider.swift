//===--- TargetBuildContextProvider.swift - SwiftDelta ------------------------------------------===//
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

public struct TargetBuildContextResolution: Sendable {
    public let contexts: [TargetBuildContext]
    public let failures: [AnalysisFailure]
    public let preflightDeferredFailures: [AnalysisFailure]
    public let excludedSourceFiles: [String]
    public let sdkIdentity: SDKInstallationIdentity?
    private let artifactLease: TemporaryDirectory?

    public init(
        contexts: [TargetBuildContext],
        failures: [AnalysisFailure],
        preflightDeferredFailures: [AnalysisFailure] = [],
        excludedSourceFiles: [String],
        sdkIdentity: SDKInstallationIdentity? = nil,
        artifactLease: TemporaryDirectory? = nil
    ) {
        self.contexts = contexts
        self.failures = failures
        self.preflightDeferredFailures = preflightDeferredFailures
        self.excludedSourceFiles = excludedSourceFiles
        self.sdkIdentity = sdkIdentity
        self.artifactLease = artifactLease
    }
}

/// Resolves the effective target model from the same Xcode, SDK, destination,
/// scheme, and configuration that will be used for analysis.
public struct TargetBuildContextProvider: Sendable {
    private let runner: any ProcessRunning
    private let inspector: XcodeContainerInspector
    private let settingsProvider: XcodeBuildSettingsProvider

    public init(runner: any ProcessRunning = ProcessRunner()) {
        self.runner = runner
        inspector = XcodeContainerInspector(runner: runner)
        settingsProvider = XcodeBuildSettingsProvider(runner: runner)
    }

    public func resolve(
        discovery: DiscoveryResult,
        configuration: SwiftDeltaConfiguration,
        xcodeApplicationPath: String,
        toolchainRole: String,
        sdkIdentifier: String,
        buildConfiguration: String? = nil,
        destination: String? = nil,
        timeout: TimeInterval,
        captureExactCompilerInvocations: Bool = true,
        cancellation: @escaping @Sendable () -> Bool = { false }
    ) throws -> TargetBuildContextResolution {
        let projectRoot = URL(fileURLWithPath: discovery.root, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let requestedScope = Set(discovery.swiftFiles.map(normalizedPath))
        let selection = ProjectDiscovery()
        let container = try selection.selectBuildContainer(
            from: discovery,
            project: configuration.defaultProject,
            workspace: configuration.defaultWorkspace
        )
        if container.kind == .package {
            return try packageContexts(
                container: container,
                projectRoot: projectRoot,
                configuration: configuration,
                xcodeApplicationPath: xcodeApplicationPath,
                toolchainRole: toolchainRole,
                sdkIdentifier: sdkIdentifier,
                buildConfiguration: buildConfiguration,
                destination: destination,
                requestedScope: requestedScope,
                timeout: timeout,
                captureExactCompilerInvocations:
                    captureExactCompilerInvocations,
                cancellation: cancellation
            )
        }

        let developerDirectory = try XcodeInstallation.validate(
            applicationPath: xcodeApplicationPath
        )
        let details = try inspector.inspect(
            container,
            developerDirectory: developerDirectory,
            timeout: min(timeout, 30)
        )
        let scheme = try selectScheme(
            configuration.defaultScheme,
            available: details.schemes
        )
        let settings = try settingsProvider.showBuildSettings(
            container: container,
            scheme: scheme,
            configuration: buildConfiguration,
            sdkIdentifier: sdkIdentifier,
            destination: destination,
            developerDirectory: developerDirectory,
            timeout: timeout
        )
        let identity = try SDKSnapshotExtractor(runner: runner).inspectIdentity(
            xcodeApplicationPath: xcodeApplicationPath,
            sdkIdentifier: sdkIdentifier,
            timeout: min(timeout, 120)
        )

        var failures: [AnalysisFailure] = []
        var preflightDeferredFailures: [AnalysisFailure] = []
        let capture: CompilerInvocationCaptureResult?
        if !captureExactCompilerInvocations {
            capture = nil
        } else {
            do {
            capture = try CompilerInvocationCapture(
                runner: runner
            ).captureXcodeBuild(
                container: container,
                scheme: scheme,
                configuration: buildConfiguration,
                sdkIdentifier: sdkIdentifier,
                destination: destination,
                developerDirectory: developerDirectory,
                timeout: timeout,
                cancellation: cancellation
            )
            if let capture, capture.buildExitStatus != 0 {
                failures.append(
                    AnalysisFailure(
                        kind: .build,
                        message:
                            "The isolated \(toolchainRole) build exited with "
                            + "status \(capture.buildExitStatus) while capturing "
                            + "compiler context. Exact invocations emitted before "
                            + "the failure remain incomplete evidence."
                            + (capture.buildFailureSummary.map {
                                " \($0)"
                            } ?? ""),
                        location: SourceLocation(path: container.path)
                    )
                )
            }
            } catch {
                capture = nil
                failures.append(
                    AnalysisFailure(
                        kind: .build,
                        message:
                            "Could not capture exact \(toolchainRole) Swift compiler "
                            + "invocations from the isolated build: "
                            + error.localizedDescription,
                        location: SourceLocation(path: container.path)
                    )
                )
            }
        }
        var membershipByProject: [String: XcodeTargetSourceMembership] = [:]
        var contexts: [TargetBuildContext] = []
        for snapshot in settings {
            let values = snapshot.settings
            let target = snapshot.target
                ?? values["TARGET_NAME"]
                ?? values["PRODUCT_NAME"]
                ?? "<unknown target>"
            let moduleName = values["PRODUCT_MODULE_NAME"] ?? target
            let platform = values["PLATFORM_NAME"] ?? sdkIdentifier
            let architecture = effectiveArchitecture(
                settings: values,
                sdkIdentifier: sdkIdentifier
            )
            let exact = capture?.bestInvocation(
                moduleName: moduleName,
                targetName: target,
                architecture: architecture
            )
            let sourceRoot = URL(
                fileURLWithPath: values["SOURCE_ROOT"] ?? projectRoot.path,
                isDirectory: true
            )
            let projectPath = values["PROJECT_FILE_PATH"]
                ?? (container.kind == .project ? container.path : nil)
            let membership: XcodeTargetSourceMembership?
            if let projectPath {
                if let cached = membershipByProject[projectPath] {
                    membership = cached
                } else {
                    do {
                        let read = try XcodeTargetSourceMembershipReader.read(
                            project: ProjectContainer(
                                kind: .project,
                                path: projectPath
                            ),
                            projectRoot: sourceRoot
                        )
                        membershipByProject[projectPath] = read
                        membership = read
                    } catch {
                        membership = nil
                        failures.append(
                            AnalysisFailure(
                                kind: .discovery,
                                message:
                                    "Could not read source membership for target "
                                    + "\(target): \(error.localizedDescription)",
                                location: SourceLocation(path: projectPath)
                            )
                        )
                    }
                }
            } else {
                membership = nil
            }
            let sourceFiles = membership?.sourceFilesByTarget[target] ?? []
            let nativeSourceFiles =
                membership?.nativeSourceFilesByTarget[target] ?? []
            let membershipReasons = membership?.unsupportedReasons ?? [
                "the selected build did not identify its project file"
            ]
            for reason in membershipReasons where exact == nil {
                let failure = AnalysisFailure(
                    kind: .discovery,
                    message: "Target \(target): \(reason).",
                    location: projectPath.map { SourceLocation(path: $0) }
                )
                failures.append(failure)
                if !captureExactCompilerInvocations {
                    preflightDeferredFailures.append(failure)
                }
            }
            if sourceFiles.isEmpty, exact == nil {
                let failure = AnalysisFailure(
                    kind: .discovery,
                    message:
                        "No Swift source membership was resolved for target "
                        + "\(target) in scheme \(scheme).",
                    location: projectPath.map { SourceLocation(path: $0) }
                )
                failures.append(failure)
                if !captureExactCompilerInvocations {
                    preflightDeferredFailures.append(failure)
                }
            }
            if !nativeSourceFiles.isEmpty {
                failures.append(
                    AnalysisFailure(
                        kind: .discovery,
                        message:
                            "Target \(target) contains \(nativeSourceFiles.count) "
                            + "Objective-C, Objective-C++, C, or C++ source file(s). "
                            + "Swift-facing Clang imports, build diagnostics, and exact "
                            + "Clang fix-its are supported, but native SDK surface "
                            + "comparison is not complete.",
                        location: projectPath.map { SourceLocation(path: $0) }
                    )
                )
            }
            let deploymentTarget = effectiveDeploymentTarget(
                settings: values,
                platform: platform
            )
            if deploymentTarget == nil {
                failures.append(
                    AnalysisFailure(
                        kind: .discovery,
                        message:
                            "Target \(target) did not expose an effective deployment "
                            + "target for platform \(platform).",
                        location: nil
                    )
                )
            }
            let buildSettingGenerated = sourceFiles.filter {
                $0.hasPrefix(values["DERIVED_SOURCES_DIR"] ?? "\u{0}")
                    || $0.hasPrefix(values["DERIVED_FILE_DIR"] ?? "\u{0}")
            }
            let membershipSources = sourceFiles.filter {
                !buildSettingGenerated.contains($0)
            }
            let activeConditions = (
                shellWords(values["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] ?? "")
                    + configuration.activeCompilationConditions
            ).filter { $0 != "$(inherited)" }
            let dependencies = membership?.dependenciesByTarget[target] ?? []
            let dependencyPaths = dependencySearchPaths(
                dependencies: dependencies,
                projectPath: projectPath,
                settings: settings
            )
            let exactSources = exact?.sourceFiles ?? []
            let exactGenerated = exactSources.filter {
                !URL(fileURLWithPath: $0)
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
                    .isContained(in: projectRoot)
            }
            let targetSources = exactSources.isEmpty
                ? membershipSources : exactSources
            let generated = exactSources.isEmpty
                ? buildSettingGenerated : exactGenerated
            let analysisSources = targetSources.filter {
                requestedScope.contains(normalizedPath($0))
            }
            let reconstructedArguments = compilerArguments(
                moduleName: moduleName,
                sdkPath: identity.sdkPath,
                sdkIdentifier: sdkIdentifier,
                platformVariant: platformVariant(
                    settings: values,
                    sdkIdentifier: sdkIdentifier
                ),
                architecture: architecture,
                deploymentTarget: deploymentTarget,
                swiftLanguageVersion: normalizedSwiftLanguageVersion(
                    values["SWIFT_VERSION"]
                ),
                conditions: Array(Set(activeConditions)).sorted(),
                otherSwiftFlags: shellWords(values["OTHER_SWIFT_FLAGS"] ?? "")
                    .filter { $0 != "$(inherited)" },
                frameworkSearchPaths:
                    searchPaths(values["FRAMEWORK_SEARCH_PATHS"])
                    + dependencyPaths,
                headerSearchPaths: searchPaths(values["HEADER_SEARCH_PATHS"]),
                moduleSearchPaths:
                    searchPaths(values["SWIFT_INCLUDE_PATHS"])
                    + dependencyPaths,
                bridgingHeader: resolvedPath(
                    values["SWIFT_OBJC_BRIDGING_HEADER"],
                    sourceRoot: sourceRoot
                ),
                strictConcurrency: values["SWIFT_STRICT_CONCURRENCY"],
                sourceFiles: analysisSources
            )
            let exactBuildSucceeded = capture?.buildExitStatus == 0
            let membershipSet = Set(membershipSources.map(normalizedPath))
            let exactProjectSet = Set(
                exactSources.filter {
                    URL(fileURLWithPath: $0)
                        .standardizedFileURL
                        .resolvingSymlinksInPath()
                        .isContained(in: projectRoot)
                }.map(normalizedPath)
            )
            let exactCoversMembership = membershipSet.isEmpty
                ? !exactProjectSet.isEmpty
                : membershipSet.isSubset(of: exactProjectSet)
            let exactIsAuthoritative = exact != nil
                && exactBuildSucceeded
                && exactCoversMembership
                && !analysisSources.isEmpty
            let effectiveArguments = exact?.analysisArguments
                ?? reconstructedArguments
            if exactIsAuthoritative {
                // The build command is retained in the context for audit. The
                // analysis command changes only compiler output mode while
                // preserving the selected build's semantic arguments.
            } else if reconstructedArguments.isEmpty {
                let failure = AnalysisFailure(
                    kind: .discovery,
                    message:
                        "Target \(target) did not expose enough build settings "
                        + "to reconstruct compiler arguments; reference analysis "
                        + "is incomplete.",
                    location: projectPath.map { SourceLocation(path: $0) }
                )
                failures.append(failure)
                if !captureExactCompilerInvocations,
                   !membershipReasons.isEmpty
                {
                    preflightDeferredFailures.append(failure)
                }
            } else if exact == nil, captureExactCompilerInvocations {
                failures.append(
                    AnalysisFailure(
                        kind: .discovery,
                        message:
                            "Target \(target) uses compiler arguments reconstructed "
                            + "from selected build settings. No exact isolated-build "
                            + "compiler invocation was available, so the context is "
                            + "retained as incomplete evidence.",
                        location: projectPath.map { SourceLocation(path: $0) }
                    )
                )
            } else if exact == nil {
                // Preflight deliberately avoids the isolated build. The
                // compatibility check must capture the exact invocation before
                // this reconstructed context can become authoritative.
            } else {
                var reasons: [String] = []
                if exactBuildSucceeded != true {
                    reasons.append("the isolated build did not complete")
                }
                if !exactCoversMembership {
                    reasons.append(
                        "captured sources did not cover the resolved target membership"
                    )
                }
                if analysisSources.isEmpty {
                    reasons.append(
                        "the captured invocation did not contain a requested source"
                    )
                }
                failures.append(
                    AnalysisFailure(
                        kind: .discovery,
                        message:
                            "Target \(target) emitted a Swift compiler command, "
                            + "but it is retained as incomplete evidence because "
                            + reasons.joined(separator: "; ")
                            + ".",
                        location: projectPath.map { SourceLocation(path: $0) }
                    )
                )
            }
            contexts.append(
                TargetBuildContext(
                    toolchainRole: toolchainRole,
                    xcodeApplicationPath: xcodeApplicationPath,
                    xcodeIdentity:
                        "Xcode \(identity.xcodeVersion) (\(identity.xcodeBuild))",
                    swiftIdentity: identity.swiftVersion,
                    sdkIdentifier: sdkIdentifier,
                    sdkPath: identity.sdkPath,
                    platform: platform,
                    platformVariant: platformVariant(
                        settings: values,
                        sdkIdentifier: sdkIdentifier
                    ),
                    containerPath: container.path,
                    projectPath: projectPath,
                    scheme: scheme,
                    target: target,
                    moduleName: moduleName,
                    configuration: snapshot.configuration ?? buildConfiguration,
                    destination: destination,
                    architecture: architecture,
                    deploymentTarget: deploymentTarget ?? "0",
                    swiftLanguageVersion: normalizedSwiftLanguageVersion(
                        values["SWIFT_VERSION"]
                    ),
                    activeCompilationConditions: Array(Set(activeConditions)).sorted(),
                    otherSwiftFlags: shellWords(values["OTHER_SWIFT_FLAGS"] ?? "")
                        .filter { $0 != "$(inherited)" },
                    frameworkSearchPaths: Array(Set(
                        searchPaths(values["FRAMEWORK_SEARCH_PATHS"])
                            + dependencyPaths
                    )).sorted(),
                    headerSearchPaths: searchPaths(
                        values["HEADER_SEARCH_PATHS"]
                    ),
                    moduleSearchPaths: Array(Set(
                        searchPaths(values["SWIFT_INCLUDE_PATHS"])
                            + dependencyPaths
                    )).sorted(),
                    bridgingHeader: resolvedPath(
                        values["SWIFT_OBJC_BRIDGING_HEADER"],
                        sourceRoot: sourceRoot
                    ),
                    strictConcurrency: values["SWIFT_STRICT_CONCURRENCY"],
                    targetDependencies: dependencies,
                    sourceFiles: targetSources,
                    analysisSourceFiles: analysisSources,
                    generatedSourceFiles: generated,
                    nativeSourceFiles: nativeSourceFiles,
                    excludedSourceFiles: [],
                    buildArtifactRoot: capture?.artifactLease.url.path,
                    capturedCompilerExecutable: exact?.executable,
                    capturedCompilerArguments: exact?.originalArguments ?? [],
                    compilerArguments: effectiveArguments,
                    evidenceSource: exact == nil
                        ? .xcodeBuildSettings : .exactCompilerInvocation,
                    isAuthoritative: exactIsAuthoritative
                )
            )
        }
        let unscopedTargetFiles = Set(contexts.flatMap(\.sourceFiles).map(normalizedPath))
        if captureExactCompilerInvocations {
            contexts = contexts.filter {
                !$0.analysisSourceFiles.isEmpty || requestedScope.isEmpty
            }
            if contexts.isEmpty, !requestedScope.isEmpty {
                failures.append(
                    AnalysisFailure(
                        kind: .discovery,
                        message:
                            "None of the requested Swift sources belong to a target "
                            + "in the selected scheme \(scheme).",
                        location: nil
                    )
                )
            }
        }
        let included = unscopedTargetFiles
        let discovered = Set(discovery.swiftFiles.map(normalizedPath))
        let excluded = discovered.subtracting(included).sorted()
        contexts = contexts.map { context in
            return TargetBuildContext(
                toolchainRole: context.toolchainRole,
                xcodeApplicationPath: context.xcodeApplicationPath,
                xcodeIdentity: context.xcodeIdentity,
                swiftIdentity: context.swiftIdentity,
                sdkIdentifier: context.sdkIdentifier,
                sdkPath: context.sdkPath,
                platform: context.platform,
                platformVariant: context.platformVariant,
                containerPath: context.containerPath,
                projectPath: context.projectPath,
                scheme: context.scheme,
                target: context.target,
                moduleName: context.moduleName,
                configuration: context.configuration,
                destination: context.destination,
                architecture: context.architecture,
                deploymentTarget: context.deploymentTarget,
                swiftLanguageVersion: context.swiftLanguageVersion,
                activeCompilationConditions: context.activeCompilationConditions,
                otherSwiftFlags: context.otherSwiftFlags,
                frameworkSearchPaths: context.frameworkSearchPaths,
                headerSearchPaths: context.headerSearchPaths,
                moduleSearchPaths: context.moduleSearchPaths,
                bridgingHeader: context.bridgingHeader,
                strictConcurrency: context.strictConcurrency,
                targetDependencies: context.targetDependencies,
                sourceFiles: context.sourceFiles,
                analysisSourceFiles: context.analysisSourceFiles,
                generatedSourceFiles: context.generatedSourceFiles,
                nativeSourceFiles: context.nativeSourceFiles,
                excludedSourceFiles: excluded,
                buildArtifactRoot: context.buildArtifactRoot,
                capturedCompilerExecutable:
                    context.capturedCompilerExecutable,
                capturedCompilerArguments:
                    context.capturedCompilerArguments,
                compilerArguments: context.compilerArguments,
                evidenceSource: context.evidenceSource,
                isAuthoritative: context.isAuthoritative
            )
        }
        return TargetBuildContextResolution(
            contexts: contexts.sorted {
                ($0.contextIdentity, $0.moduleName)
                    < ($1.contextIdentity, $1.moduleName)
            },
            failures: failures,
            preflightDeferredFailures: preflightDeferredFailures,
            excludedSourceFiles: excluded,
            sdkIdentity: identity,
            artifactLease: capture?.artifactLease
        )
    }

    private func packageContexts(
        container: ProjectContainer,
        projectRoot: URL,
        configuration: SwiftDeltaConfiguration,
        xcodeApplicationPath: String,
        toolchainRole: String,
        sdkIdentifier: String,
        buildConfiguration: String?,
        destination: String?,
        requestedScope: Set<String>,
        timeout: TimeInterval,
        captureExactCompilerInvocations: Bool,
        cancellation: @escaping @Sendable () -> Bool
    ) throws -> TargetBuildContextResolution {
        let identity = try SDKSnapshotExtractor(runner: runner).inspectIdentity(
            xcodeApplicationPath: xcodeApplicationPath,
            sdkIdentifier: sdkIdentifier,
            timeout: min(timeout, 120)
        )
        let manifest = URL(fileURLWithPath: container.path)
        let root = manifest.deletingLastPathComponent()
        let description = try packageDescription(
            root: root,
            xcodeApplicationPath: xcodeApplicationPath,
            timeout: timeout,
            cancellation: cancellation
        )
        let discovered = requestedScope
        let platformName = packagePlatformName(sdkIdentifier)
        let deployment = description.platforms[platformName]
            ?? defaultPackageDeploymentTarget(sdkIdentifier)
        let hasExplicitDeployment =
            description.platforms[platformName] != nil
        let capture: CompilerInvocationCaptureResult?
        var failures: [AnalysisFailure] = []
        if !captureExactCompilerInvocations {
            capture = nil
        } else {
            do {
            capture = try CompilerInvocationCapture(
                runner: runner
            ).captureSwiftPackageBuild(
                packageRoot: root,
                xcodeApplicationPath: xcodeApplicationPath,
                sdkPath: identity.sdkPath,
                targetTriple: targetTriple(
                    sdkIdentifier: sdkIdentifier,
                    platformVariant: sdkIdentifier.contains("simulator")
                        ? "simulator" : nil,
                    architecture: "arm64",
                    deploymentTarget: deployment
                ),
                configuration: buildConfiguration,
                timeout: timeout,
                cancellation: cancellation
            )
            if let capture, capture.buildExitStatus != 0 {
                failures.append(
                    AnalysisFailure(
                        kind: .build,
                        message:
                            "The isolated \(toolchainRole) Swift Package build "
                            + "exited with status \(capture.buildExitStatus) "
                            + "while capturing exact compiler context."
                            + (capture.buildFailureSummary.map {
                                " \($0)"
                            } ?? ""),
                        location: SourceLocation(path: manifest.path)
                    )
                )
            }
            } catch {
                capture = nil
                failures.append(
                    AnalysisFailure(
                        kind: .build,
                        message:
                            "Could not capture exact \(toolchainRole) Swift Package "
                            + "compiler invocations: \(error.localizedDescription)",
                        location: SourceLocation(path: manifest.path)
                    )
                )
            }
        }
        let pluginTargets = Set(
            description.targets.compactMap { name, target in
                let type = "\(target.type) \(target.moduleType)".lowercased()
                return type.contains("macro") || type.contains("plugin")
                    ? name
                    : nil
            }
        )
        if !hasExplicitDeployment {
            failures.append(
                AnalysisFailure(
                    kind: .discovery,
                    message:
                        "The selected package description did not provide an "
                        + "explicit \(platformName) deployment target; the "
                        + "fallback target \(deployment) is non-authoritative.",
                    location: SourceLocation(path: manifest.path)
                )
            )
        }
        let contexts = description.targets.map { target, details in
            let moduleName = target.replacingOccurrences(
                of: "-",
                with: "_"
            )
            let exact = capture?.bestInvocation(
                moduleName: moduleName,
                targetName: target,
                architecture: "arm64"
            )
            let membership = Set(details.files.map(normalizedPath))
            let exactProjectSources = exact?.sourceFiles.filter {
                URL(fileURLWithPath: $0)
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
                    .isContained(in: projectRoot)
            } ?? []
            let exactCoversMembership = !membership.isEmpty
                && membership.isSubset(
                    of: Set(exactProjectSources.map(normalizedPath))
                )
            let exactIsAuthoritative = exact != nil
                && capture?.buildExitStatus == 0
                && hasExplicitDeployment
                && exactCoversMembership
            let sourceFiles = exact?.sourceFiles ?? details.files
            let generated = sourceFiles.filter {
                !URL(fileURLWithPath: $0)
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
                    .isContained(in: projectRoot)
            }
            let analysisSources = sourceFiles.filter {
                discovered.contains(normalizedPath($0))
            }
            let pluginDependencies = Set(details.dependencies)
                .intersection(pluginTargets)
            if !details.dependencies.isEmpty, !exactIsAuthoritative {
                failures.append(
                    AnalysisFailure(
                        kind: .discovery,
                        message:
                            "Package target \(target) depends on "
                            + details.dependencies.joined(separator: ", ")
                            + "; reusable dependency module artifacts were not "
                            + "available to reference analysis.",
                        location: SourceLocation(path: manifest.path)
                    )
                )
            }
            if (!pluginDependencies.isEmpty || pluginTargets.contains(target)),
               !exactIsAuthoritative
            {
                failures.append(
                    AnalysisFailure(
                        kind: .discovery,
                        message:
                            "Package target \(target) requires macro or compiler "
                            + "plugin context that cannot be reconstructed from "
                            + "package description metadata alone.",
                        location: SourceLocation(path: manifest.path)
                    )
                )
            }
            return TargetBuildContext(
                toolchainRole: toolchainRole,
                xcodeApplicationPath: xcodeApplicationPath,
                xcodeIdentity:
                    "Xcode \(identity.xcodeVersion) (\(identity.xcodeBuild))",
                swiftIdentity: identity.swiftVersion,
                sdkIdentifier: sdkIdentifier,
                sdkPath: identity.sdkPath,
                platform: identity.platform,
                platformVariant: sdkIdentifier.contains("simulator")
                    ? "simulator"
                    : nil,
                containerPath: container.path,
                projectPath: nil,
                scheme: nil,
                target: target,
                moduleName: moduleName,
                configuration: buildConfiguration,
                destination: destination,
                architecture: sdkIdentifier.contains("simulator")
                    ? "arm64"
                    : "arm64",
                deploymentTarget: deployment,
                activeCompilationConditions:
                    configuration.activeCompilationConditions,
                targetDependencies: details.dependencies,
                sourceFiles: sourceFiles,
                analysisSourceFiles: analysisSources,
                generatedSourceFiles: generated,
                buildArtifactRoot: capture?.artifactLease.url.path,
                capturedCompilerExecutable: exact?.executable,
                capturedCompilerArguments: exact?.originalArguments ?? [],
                compilerArguments: exact?.analysisArguments
                    ?? compilerArguments(
                    moduleName: moduleName,
                    sdkPath: identity.sdkPath,
                    sdkIdentifier: sdkIdentifier,
                    platformVariant: sdkIdentifier.contains("simulator")
                        ? "simulator" : nil,
                    architecture: "arm64",
                    deploymentTarget: deployment,
                    swiftLanguageVersion: nil,
                    conditions: configuration.activeCompilationConditions,
                    otherSwiftFlags: [],
                    frameworkSearchPaths: [],
                    headerSearchPaths: [],
                    moduleSearchPaths: [],
                    bridgingHeader: nil,
                    strictConcurrency: nil,
                    sourceFiles: analysisSources
                ),
                evidenceSource: exact == nil
                    ? .swiftPackageDescription : .exactCompilerInvocation,
                isAuthoritative: exactIsAuthoritative
            )
        }
        let scopedContexts = contexts.filter {
            !$0.analysisSourceFiles.isEmpty || discovered.isEmpty
        }
        let included = Set(contexts.flatMap(\.sourceFiles).map(normalizedPath))
        return TargetBuildContextResolution(
            contexts: scopedContexts.sorted { $0.target < $1.target },
            failures: failures + (
                scopedContexts.isEmpty && !discovered.isEmpty
                ? [
                    AnalysisFailure(
                        kind: .discovery,
                        message:
                            "None of the requested Swift sources belong to a "
                            + "locally described package target.",
                        location: nil
                    ),
                ]
                : []
            ),
            excludedSourceFiles: discovered.subtracting(included).sorted(),
            sdkIdentity: identity,
            artifactLease: capture?.artifactLease
        )
    }

    private struct PackageTargetDescription {
        let files: [String]
        let dependencies: [String]
        let type: String
        let moduleType: String
    }

    private struct LocalPackageDescription {
        let targets: [String: PackageTargetDescription]
        let platforms: [String: String]
    }

    private func packageDescription(
        root: URL,
        xcodeApplicationPath: String,
        timeout: TimeInterval,
        cancellation: @escaping @Sendable () -> Bool
    ) throws -> LocalPackageDescription {
        let developerDirectory = try XcodeInstallation.validate(
            applicationPath: xcodeApplicationPath
        )
        let swift = URL(fileURLWithPath: developerDirectory)
            .appendingPathComponent(
                "Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
            )
        let temporary = try TemporaryDirectory(
            prefix: "swiftdelta-package-description"
        )
        defer { temporary.remove() }
        let moduleCache = temporary.url.appendingPathComponent(
            "module-cache",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: moduleCache,
            withIntermediateDirectories: true
        )
        let cache = temporary.url.appendingPathComponent(
            "cache",
            isDirectory: true
        )
        let configuration = temporary.url.appendingPathComponent(
            "configuration",
            isDirectory: true
        )
        let security = temporary.url.appendingPathComponent(
            "security",
            isDirectory: true
        )
        for directory in [cache, configuration, security] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        try SwiftPackageDependencyCacheSeeder.seed(
            packageRoot: root,
            isolatedCache: cache
        )
        let processResult = try runner.run(
            executable: swift.path,
            arguments: [
                "package",
                "--package-path", root.path,
                "--scratch-path", temporary.url.appendingPathComponent("scratch").path,
                "--cache-path", cache.path,
                "--config-path", configuration.path,
                "--security-path", security.path,
                "--disable-automatic-resolution",
                "--disable-prefetching",
                "--skip-update",
                "describe",
                "--type", "json",
            ],
            environment: [
                "DEVELOPER_DIR": developerDirectory,
                "CLANG_MODULE_CACHE_PATH": moduleCache.path,
                "SWIFTPM_MODULECACHE_OVERRIDE": moduleCache.path,
            ],
            workingDirectory: root,
            timeout: timeout,
            cancellation: cancellation
        )
        guard processResult.exitStatus == 0 else {
            throw SwiftDeltaError.processFailed(
                executable: "swift package describe",
                status: processResult.exitStatus,
                message: processResult.safeErrorSummary
            )
        }
        guard let object = try JSONSerialization.jsonObject(
            with: processResult.standardOutput
        ) as? [String: Any],
            let targets = object["targets"] as? [[String: Any]]
        else {
            throw SwiftDeltaError.invalidConfiguration(
                field: "Package.swift",
                reason: "swift package describe returned malformed target metadata"
            )
        }
        var result: [String: PackageTargetDescription] = [:]
        for target in targets {
            guard let name = target["name"] as? String,
                  let targetPath = target["path"] as? String
            else {
                continue
            }
            let directory = URL(fileURLWithPath: targetPath, relativeTo: root)
                .standardizedFileURL
            let files = (target["sources"] as? [String] ?? [])
                .filter { $0.lowercased().hasSuffix(".swift") }
                .map { directory.appendingPathComponent($0).canonicalPath }
                .sorted()
            let dependencies = target["target_dependencies"] as? [String]
                ?? (target["dependencies"] as? [[String: Any]] ?? [])
                    .compactMap {
                        ($0["name"] as? String)
                            ?? ($0["target"] as? String)
                    }
            result[name] = PackageTargetDescription(
                files: files,
                dependencies: dependencies.sorted(),
                type: target["type"] as? String ?? "",
                moduleType: target["module_type"] as? String ?? ""
            )
        }
        let platforms = (object["platforms"] as? [[String: Any]] ?? [])
            .reduce(into: [String: String]()) { result, value in
                guard let name = value["name"] as? String,
                      let version = value["version"] as? String
                else {
                    return
                }
                result[name.lowercased()] = version
            }
        return LocalPackageDescription(
            targets: result,
            platforms: platforms
        )
    }

    private func selectScheme(
        _ configured: String?,
        available: [String]
    ) throws -> String {
        if let configured {
            guard available.contains(configured) else {
                throw SwiftDeltaError.invalidConfiguration(
                    field: "scheme",
                    reason: "'\(configured)' is not a shared scheme"
                )
            }
            return configured
        }
        guard available.count == 1, let only = available.first else {
            throw SwiftDeltaError.ambiguousSelection(
                kind: "scheme",
                choices: available
            )
        }
        return only
    }

    private func effectiveArchitecture(
        settings: [String: String],
        sdkIdentifier: String
    ) -> String {
        let current = settings["CURRENT_ARCH"]
        if let current, !current.isEmpty, current != "undefined_arch" {
            return current
        }
        return shellWords(settings["ARCHS"] ?? "").first ?? ""
    }

    private func effectiveDeploymentTarget(
        settings: [String: String],
        platform: String
    ) -> String? {
        let key: String
        switch platform.lowercased() {
        case let value where value.contains("iphone"): key = "IPHONEOS_DEPLOYMENT_TARGET"
        case let value where value.contains("appletv"): key = "TVOS_DEPLOYMENT_TARGET"
        case let value where value.contains("watch"): key = "WATCHOS_DEPLOYMENT_TARGET"
        case let value where value.contains("xros"): key = "XROS_DEPLOYMENT_TARGET"
        default: key = "MACOSX_DEPLOYMENT_TARGET"
        }
        return settings[key].flatMap { $0.isEmpty ? nil : $0 }
    }

    private func platformVariant(
        settings: [String: String],
        sdkIdentifier: String
    ) -> String? {
        if settings["IS_MACCATALYST"] == "YES"
            || settings["EFFECTIVE_PLATFORM_NAME"] == "-maccatalyst"
        {
            return "macCatalyst"
        }
        if sdkIdentifier.lowercased().contains("simulator")
            || settings["EFFECTIVE_PLATFORM_NAME"]?.contains("simulator") == true
        {
            return "simulator"
        }
        return nil
    }

    private func searchPaths(_ value: String?) -> [String] {
        shellWords(value ?? "").filter {
            !$0.isEmpty
                && $0 != "$(inherited)"
                && !$0.contains("$(")
        }
    }

    private func dependencySearchPaths(
        dependencies: [String],
        projectPath: String?,
        settings: [BuildSettingsSnapshot]
    ) -> [String] {
        guard !dependencies.isEmpty else { return [] }
        let values = settings.compactMap { snapshot -> [String]? in
            let build = snapshot.settings
            let name = snapshot.target
                ?? build["TARGET_NAME"]
                ?? build["PRODUCT_NAME"]
            guard let name, dependencies.contains(name) else {
                return nil
            }
            if let projectPath,
               let dependencyProject = build["PROJECT_FILE_PATH"],
               normalizedPath(projectPath) != normalizedPath(dependencyProject)
            {
                return nil
            }
            return [
                build["BUILT_PRODUCTS_DIR"],
                build["CONFIGURATION_BUILD_DIR"],
                build["SWIFT_MODULE_DIRECTORY"],
                build["TARGET_BUILD_DIR"],
            ].compactMap { path in
                guard let path,
                      !path.isEmpty,
                      !path.contains("$(")
                else {
                    return nil
                }
                return URL(fileURLWithPath: path).canonicalPath
            }
        }.flatMap { $0 }
        return Array(Set(values)).sorted()
    }

    /// Produces a target-derived invocation when the selected build did not
    /// expose its exact Swift command. Callers must keep this context
    /// non-authoritative; the arguments are still preferable to a
    /// whole-directory compiler invocation because they retain target
    /// membership and effective build settings.
    private func compilerArguments(
        moduleName: String,
        sdkPath: String,
        sdkIdentifier: String,
        platformVariant: String?,
        architecture: String,
        deploymentTarget: String?,
        swiftLanguageVersion: String?,
        conditions: [String],
        otherSwiftFlags: [String],
        frameworkSearchPaths: [String],
        headerSearchPaths: [String],
        moduleSearchPaths: [String],
        bridgingHeader: String?,
        strictConcurrency: String?,
        sourceFiles: [String]
    ) -> [String] {
        guard !moduleName.isEmpty,
              !sdkPath.isEmpty,
              !architecture.isEmpty,
              let deploymentTarget,
              !deploymentTarget.isEmpty,
              !sourceFiles.isEmpty
        else {
            return []
        }
        var arguments = [
            "-typecheck",
            "-parse-as-library",
            "-dump-ast",
            "-dump-ast-format", "json",
            "-j1",
            "-module-name", moduleName,
            "-sdk", sdkPath,
            "-target", targetTriple(
                sdkIdentifier: sdkIdentifier,
                platformVariant: platformVariant,
                architecture: architecture,
                deploymentTarget: deploymentTarget
            ),
            "-module-cache-path", "<SWIFTDELTA_MODULE_CACHE>",
        ]
        if let swiftLanguageVersion {
            arguments.append(
                contentsOf: ["-swift-version", swiftLanguageVersion]
            )
        }
        for condition in Array(Set(conditions)).sorted()
            where isValidCompilationCondition(condition)
        {
            arguments.append(contentsOf: ["-D", condition])
        }
        arguments.append(contentsOf: otherSwiftFlags)
        for path in Array(Set(frameworkSearchPaths)).sorted() {
            arguments.append(contentsOf: ["-F", path])
        }
        for path in Array(Set(headerSearchPaths)).sorted() {
            arguments.append(contentsOf: ["-Xcc", "-I\(path)"])
        }
        for path in Array(Set(moduleSearchPaths)).sorted() {
            arguments.append(contentsOf: ["-I", path])
        }
        if let bridgingHeader {
            arguments.append(
                contentsOf: ["-import-objc-header", bridgingHeader]
            )
        }
        if let strictConcurrency, !strictConcurrency.isEmpty {
            arguments.append("-strict-concurrency=\(strictConcurrency)")
        }
        arguments.append(contentsOf: sourceFiles.sorted())
        return arguments
    }

    private func targetTriple(
        sdkIdentifier: String,
        platformVariant: String?,
        architecture: String,
        deploymentTarget: String
    ) -> String {
        switch sdkIdentifier.lowercased() {
        case "iphoneos":
            return "\(architecture)-apple-ios\(deploymentTarget)"
        case "iphonesimulator":
            return "\(architecture)-apple-ios\(deploymentTarget)-simulator"
        case "appletvos":
            return "\(architecture)-apple-tvos\(deploymentTarget)"
        case "appletvsimulator":
            return "\(architecture)-apple-tvos\(deploymentTarget)-simulator"
        case "watchos":
            return "\(architecture)-apple-watchos\(deploymentTarget)"
        case "watchsimulator":
            return "\(architecture)-apple-watchos\(deploymentTarget)-simulator"
        case "xros":
            return "\(architecture)-apple-xros\(deploymentTarget)"
        case "xrsimulator":
            return "\(architecture)-apple-xros\(deploymentTarget)-simulator"
        default:
            if platformVariant == "macCatalyst" {
                return "\(architecture)-apple-ios\(deploymentTarget)-macabi"
            }
            return "\(architecture)-apple-macosx\(deploymentTarget)"
        }
    }

    private func isValidCompilationCondition(_ value: String) -> Bool {
        value.range(
            of: #"^[A-Za-z_][A-Za-z0-9_]*$"#,
            options: .regularExpression
        ) != nil
    }

    private func resolvedPath(_ value: String?, sourceRoot: URL) -> String? {
        guard let value, !value.isEmpty else {
            return nil
        }
        if NSString(string: value).isAbsolutePath {
            return URL(fileURLWithPath: value).canonicalPath
        }
        return sourceRoot.appendingPathComponent(value).canonicalPath
    }

    private func shellWords(_ value: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for character in value {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character.isWhitespace {
                if !current.isEmpty {
                    words.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty {
            words.append(current)
        }
        return words
    }

    private func normalizedPath(_ value: String) -> String {
        URL(fileURLWithPath: value).canonicalPath
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

    private func normalizedSwiftLanguageVersion(
        _ value: String?
    ) -> String? {
        guard let value = value?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else {
            return nil
        }
        let components = value.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard components.count > 1,
              components.dropFirst().allSatisfy({ component in
                  !component.isEmpty && component.allSatisfy { $0 == "0" }
              })
        else {
            return value
        }
        return String(components[0])
    }

    private func defaultPackageDeploymentTarget(_ sdkIdentifier: String) -> String {
        switch sdkIdentifier.lowercased() {
        case "iphoneos", "iphonesimulator": "13.0"
        case "appletvos", "appletvsimulator": "13.0"
        case "watchos", "watchsimulator": "6.0"
        case "xros", "xrsimulator": "1.0"
        default: "10.15"
        }
    }
}
