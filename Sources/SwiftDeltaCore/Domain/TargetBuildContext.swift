//===--- TargetBuildContext.swift - SwiftDelta ------------------------------------------===//
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

public enum BuildContextEvidenceSource: String, Codable, Hashable, Sendable {
    case xcodeBuild
    case xcodeBuildSettings
    case swiftPackageDescription
    case exactCompilerInvocation
    case configuredFallback
}

/// Compiler context for one concrete target, platform, and selected toolchain.
///
/// A context is authoritative only when its source membership and compiler
/// arguments came from the selected build. Configured fallbacks remain useful
/// for partial evidence, but must not produce a complete analysis result.
public struct TargetBuildContext: Codable, Hashable, Sendable {
    public let toolchainRole: String
    public let xcodeApplicationPath: String
    public let xcodeIdentity: String?
    public let swiftIdentity: String?
    public let sdkIdentifier: String
    public let sdkPath: String
    public let platform: String
    public let platformVariant: String?
    public let containerPath: String?
    public let projectPath: String?
    public let scheme: String?
    public let target: String
    public let moduleName: String
    public let configuration: String?
    public let destination: String?
    public let architecture: String
    public let deploymentTarget: String
    public let swiftLanguageVersion: String?
    public let activeCompilationConditions: [String]
    public let otherSwiftFlags: [String]
    public let frameworkSearchPaths: [String]
    public let headerSearchPaths: [String]
    public let moduleSearchPaths: [String]
    public let bridgingHeader: String?
    public let strictConcurrency: String?
    public let targetDependencies: [String]
    public let sourceFiles: [String]
    public let analysisSourceFiles: [String]
    public let generatedSourceFiles: [String]
    public let nativeSourceFiles: [String]
    public let excludedSourceFiles: [String]
    public let buildArtifactRoot: String?
    public let capturedCompilerExecutable: String?
    public let capturedCompilerArguments: [String]
    public let compilerArguments: [String]
    public let evidenceSource: BuildContextEvidenceSource
    public let isAuthoritative: Bool

    public init(
        toolchainRole: String,
        xcodeApplicationPath: String,
        xcodeIdentity: String? = nil,
        swiftIdentity: String? = nil,
        sdkIdentifier: String,
        sdkPath: String,
        platform: String,
        platformVariant: String? = nil,
        containerPath: String? = nil,
        projectPath: String? = nil,
        scheme: String? = nil,
        target: String,
        moduleName: String,
        configuration: String? = nil,
        destination: String? = nil,
        architecture: String,
        deploymentTarget: String,
        swiftLanguageVersion: String? = nil,
        activeCompilationConditions: [String] = [],
        otherSwiftFlags: [String] = [],
        frameworkSearchPaths: [String] = [],
        headerSearchPaths: [String] = [],
        moduleSearchPaths: [String] = [],
        bridgingHeader: String? = nil,
        strictConcurrency: String? = nil,
        targetDependencies: [String] = [],
        sourceFiles: [String],
        analysisSourceFiles: [String]? = nil,
        generatedSourceFiles: [String] = [],
        nativeSourceFiles: [String] = [],
        excludedSourceFiles: [String] = [],
        buildArtifactRoot: String? = nil,
        capturedCompilerExecutable: String? = nil,
        capturedCompilerArguments: [String] = [],
        compilerArguments: [String],
        evidenceSource: BuildContextEvidenceSource,
        isAuthoritative: Bool
    ) {
        self.toolchainRole = toolchainRole
        self.xcodeApplicationPath = xcodeApplicationPath
        self.xcodeIdentity = xcodeIdentity
        self.swiftIdentity = swiftIdentity
        self.sdkIdentifier = sdkIdentifier
        self.sdkPath = sdkPath
        self.platform = platform
        self.platformVariant = platformVariant
        self.containerPath = containerPath
        self.projectPath = projectPath
        self.scheme = scheme
        self.target = target
        self.moduleName = moduleName
        self.configuration = configuration
        self.destination = destination
        self.architecture = architecture
        self.deploymentTarget = deploymentTarget
        self.swiftLanguageVersion = swiftLanguageVersion
        self.activeCompilationConditions = activeCompilationConditions
        self.otherSwiftFlags = otherSwiftFlags
        self.frameworkSearchPaths = frameworkSearchPaths
        self.headerSearchPaths = headerSearchPaths
        self.moduleSearchPaths = moduleSearchPaths
        self.bridgingHeader = bridgingHeader
        self.strictConcurrency = strictConcurrency
        self.targetDependencies = targetDependencies
        self.sourceFiles = sourceFiles
        self.analysisSourceFiles = analysisSourceFiles ?? sourceFiles
        self.generatedSourceFiles = generatedSourceFiles
        self.nativeSourceFiles = nativeSourceFiles
        self.excludedSourceFiles = excludedSourceFiles
        self.buildArtifactRoot = buildArtifactRoot
        self.capturedCompilerExecutable = capturedCompilerExecutable
        self.capturedCompilerArguments = capturedCompilerArguments
        self.compilerArguments = compilerArguments
        self.evidenceSource = evidenceSource
        self.isAuthoritative = isAuthoritative
    }

    /// Stable identity for one target in one selected build container.
    public var contextIdentity: String {
        [
            containerPath ?? "",
            projectPath ?? "",
            scheme ?? "",
            target,
            moduleName,
            configuration ?? "",
            sdkIdentifier,
            destination ?? "",
            architecture,
            platformVariant ?? "",
        ].joined(separator: "|")
    }
}
