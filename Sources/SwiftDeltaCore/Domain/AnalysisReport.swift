//===--- AnalysisReport.swift - SwiftDelta ------------------------------------------===//
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

public enum AnalysisResultState: String, Codable, Hashable, Sendable {
    case completeAndClean
    case completeWithFindings
    case incomplete
    case blocked
}

public enum SourceAnalysisDisposition: String, Codable, Hashable, Sendable {
    case analyzedWithSDKReferences
    case analyzedWithoutSDKReferences
    case failed
    case missingCompilerOutput
    case excludedFromTarget
    case generated
    case unreadable
    case unsupported

    public var isSuccessful: Bool {
        self == .analyzedWithSDKReferences || self == .analyzedWithoutSDKReferences
    }
}

public struct SourceAnalysisRecord: Codable, Hashable, Sendable {
    public let path: String
    public let disposition: SourceAnalysisDisposition
    public let reason: String?

    public init(
        path: String,
        disposition: SourceAnalysisDisposition,
        reason: String? = nil
    ) {
        self.path = path
        self.disposition = disposition
        self.reason = reason
    }
}

public struct SDKModuleSelectionEvidence: Codable, Hashable, Sendable {
    public let toolchainRole: String
    public let sdkIdentifier: String
    public let moduleName: String
    public let target: String?
    public let reason: String
    public let sourcePaths: [String]

    public init(
        toolchainRole: String,
        sdkIdentifier: String,
        moduleName: String,
        target: String? = nil,
        reason: String,
        sourcePaths: [String] = []
    ) {
        self.toolchainRole = toolchainRole
        self.sdkIdentifier = sdkIdentifier
        self.moduleName = moduleName
        self.target = target
        self.reason = reason
        self.sourcePaths = sourcePaths
    }
}

public struct ReferenceResolutionCoverage: Codable, Hashable, Sendable {
    public let sdkIdentifier: String
    public let toolchainRole: String?
    public let xcodeIdentity: String?
    public let swiftIdentity: String?
    public let platform: String?
    public let scheme: String?
    public let target: String?
    public let configuration: String?
    public let destination: String?
    public let architecture: String?
    public let deploymentTarget: String?
    public let filesRequested: Int
    public let filesAnalyzed: Int
    public let filesWithoutSDKReferences: Int
    public let filesFailed: Int
    public let declarationReferences: Int
    public let stableIdentityReferences: Int
    public let unresolvedReferences: Int
    public let unresolvedReasons: [String: Int]
    public let compilerExitStatus: Int32?
    public let isComplete: Bool
    public let sourceFiles: [SourceAnalysisRecord]

    public init(
        sdkIdentifier: String,
        toolchainRole: String? = nil,
        xcodeIdentity: String? = nil,
        swiftIdentity: String? = nil,
        platform: String? = nil,
        scheme: String? = nil,
        target: String? = nil,
        configuration: String? = nil,
        destination: String? = nil,
        architecture: String? = nil,
        deploymentTarget: String? = nil,
        filesRequested: Int = 0,
        filesAnalyzed: Int = 0,
        filesWithoutSDKReferences: Int = 0,
        filesFailed: Int = 0,
        declarationReferences: Int = 0,
        stableIdentityReferences: Int = 0,
        unresolvedReferences: Int = 0,
        unresolvedReasons: [String: Int] = [:],
        compilerExitStatus: Int32? = nil,
        isComplete: Bool? = nil,
        sourceFiles: [SourceAnalysisRecord] = []
    ) {
        self.sdkIdentifier = sdkIdentifier
        self.toolchainRole = toolchainRole
        self.xcodeIdentity = xcodeIdentity
        self.swiftIdentity = swiftIdentity
        self.platform = platform
        self.scheme = scheme
        self.target = target
        self.configuration = configuration
        self.destination = destination
        self.architecture = architecture
        self.deploymentTarget = deploymentTarget
        self.filesRequested = filesRequested
        self.filesAnalyzed = filesAnalyzed
        self.filesWithoutSDKReferences = filesWithoutSDKReferences
        self.filesFailed = filesFailed
        self.declarationReferences = declarationReferences
        self.stableIdentityReferences = stableIdentityReferences
        self.unresolvedReferences = unresolvedReferences
        self.unresolvedReasons = unresolvedReasons
        self.compilerExitStatus = compilerExitStatus
        self.isComplete = isComplete
            ?? (filesAnalyzed == filesRequested
                && filesFailed == 0
                && (compilerExitStatus == nil || compilerExitStatus == 0))
        self.sourceFiles = sourceFiles
    }

    private enum CodingKeys: String, CodingKey {
        case sdkIdentifier
        case toolchainRole
        case xcodeIdentity
        case swiftIdentity
        case platform
        case scheme
        case target
        case configuration
        case destination
        case architecture
        case deploymentTarget
        case filesRequested
        case filesAnalyzed
        case filesWithoutSDKReferences
        case filesFailed
        case declarationReferences
        case stableIdentityReferences
        case unresolvedReferences
        case unresolvedReasons
        case compilerExitStatus
        case isComplete
        case sourceFiles
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sdkIdentifier = try values.decode(String.self, forKey: .sdkIdentifier)
        toolchainRole = try values.decodeIfPresent(String.self, forKey: .toolchainRole)
        xcodeIdentity = try values.decodeIfPresent(String.self, forKey: .xcodeIdentity)
        swiftIdentity = try values.decodeIfPresent(String.self, forKey: .swiftIdentity)
        platform = try values.decodeIfPresent(String.self, forKey: .platform)
        scheme = try values.decodeIfPresent(String.self, forKey: .scheme)
        target = try values.decodeIfPresent(String.self, forKey: .target)
        configuration = try values.decodeIfPresent(String.self, forKey: .configuration)
        destination = try values.decodeIfPresent(String.self, forKey: .destination)
        architecture = try values.decodeIfPresent(String.self, forKey: .architecture)
        deploymentTarget = try values.decodeIfPresent(String.self, forKey: .deploymentTarget)
        filesRequested = try values.decodeIfPresent(Int.self, forKey: .filesRequested) ?? 0
        filesAnalyzed = try values.decodeIfPresent(Int.self, forKey: .filesAnalyzed) ?? 0
        filesWithoutSDKReferences =
            try values.decodeIfPresent(Int.self, forKey: .filesWithoutSDKReferences) ?? 0
        filesFailed = try values.decodeIfPresent(Int.self, forKey: .filesFailed) ?? 0
        declarationReferences =
            try values.decodeIfPresent(Int.self, forKey: .declarationReferences) ?? 0
        stableIdentityReferences =
            try values.decodeIfPresent(Int.self, forKey: .stableIdentityReferences) ?? 0
        unresolvedReferences =
            try values.decodeIfPresent(Int.self, forKey: .unresolvedReferences) ?? 0
        unresolvedReasons =
            try values.decodeIfPresent([String: Int].self, forKey: .unresolvedReasons) ?? [:]
        compilerExitStatus = try values.decodeIfPresent(Int32.self, forKey: .compilerExitStatus)
        sourceFiles =
            try values.decodeIfPresent([SourceAnalysisRecord].self, forKey: .sourceFiles) ?? []
        isComplete = try values.decodeIfPresent(Bool.self, forKey: .isComplete)
            ?? (filesAnalyzed == filesRequested
                && filesFailed == 0
                && (compilerExitStatus == nil || compilerExitStatus == 0))
    }
}

public struct EnvironmentSnapshot: Codable, Equatable, Sendable {
    public let xcodeVersion: String?
    public let swiftVersion: String?
    public let sdkVersion: String?
    public let developerDirectory: String?

    public init(
        xcodeVersion: String? = nil,
        swiftVersion: String? = nil,
        sdkVersion: String? = nil,
        developerDirectory: String? = nil
    ) {
        self.xcodeVersion = xcodeVersion
        self.swiftVersion = swiftVersion
        self.sdkVersion = sdkVersion
        self.developerDirectory = developerDirectory
    }
}

public struct AnalysisReport: Codable, Sendable {
    public static let currentFormatVersion = "3.0"

    public let reportFormatVersion: String
    public let generatedAt: Date
    public let projectRoot: String
    public let targetXcodeVersion: String?
    public let environment: EnvironmentSnapshot?
    public let baselineEnvironment: EnvironmentSnapshot?
    public let candidateEnvironment: EnvironmentSnapshot?
    public let analysisState: AnalysisResultState
    public let referenceResolutionCoverage: [ReferenceResolutionCoverage]
    public let sdkModuleSelections: [SDKModuleSelectionEvidence]
    public let findings: [Finding]
    public let failures: [AnalysisFailure]

    public init(
        generatedAt: Date = Date(),
        projectRoot: String,
        targetXcodeVersion: String? = nil,
        environment: EnvironmentSnapshot? = nil,
        baselineEnvironment: EnvironmentSnapshot? = nil,
        candidateEnvironment: EnvironmentSnapshot? = nil,
        analysisState: AnalysisResultState? = nil,
        referenceResolutionCoverage: [ReferenceResolutionCoverage] = [],
        sdkModuleSelections: [SDKModuleSelectionEvidence] = [],
        findings: [Finding],
        failures: [AnalysisFailure] = []
    ) {
        self.reportFormatVersion = Self.currentFormatVersion
        self.generatedAt = generatedAt
        self.projectRoot = projectRoot
        self.targetXcodeVersion = targetXcodeVersion
        self.environment = environment
        self.baselineEnvironment = baselineEnvironment
        self.candidateEnvironment = candidateEnvironment
        self.analysisState = analysisState ?? Self.inferState(
            findings: findings,
            coverage: referenceResolutionCoverage
        )
        self.referenceResolutionCoverage = referenceResolutionCoverage
        self.sdkModuleSelections = sdkModuleSelections
        self.findings = findings
        self.failures = failures
    }

    private static func inferState(
        findings: [Finding],
        coverage: [ReferenceResolutionCoverage]
    ) -> AnalysisResultState {
        if coverage.contains(where: { !$0.isComplete }) {
            return .incomplete
        }
        return findings.isEmpty ? .completeAndClean : .completeWithFindings
    }
}
