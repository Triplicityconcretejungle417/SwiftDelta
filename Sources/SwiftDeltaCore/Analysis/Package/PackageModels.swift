//===--- PackageModels.swift - SwiftDelta ------------------------------------------===//
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

public struct PackageMetadata: Codable, Equatable, Sendable {
    public let manifestPath: String
    public let toolsVersion: String?
    public let minimumPlatforms: [String: String]
    public let resolvedFilePresent: Bool
    public let resolvedDependencyCount: Int?
    public let binaryTargets: [String]
    public let binaryTargetSlices: [String: [BinaryTargetSlice]]
    public let pluginCount: Int

    public init(
        manifestPath: String,
        toolsVersion: String?,
        minimumPlatforms: [String: String],
        resolvedFilePresent: Bool,
        resolvedDependencyCount: Int?,
        binaryTargets: [String],
        binaryTargetSlices: [String: [BinaryTargetSlice]] = [:],
        pluginCount: Int
    ) {
        self.manifestPath = manifestPath
        self.toolsVersion = toolsVersion
        self.minimumPlatforms = minimumPlatforms
        self.resolvedFilePresent = resolvedFilePresent
        self.resolvedDependencyCount = resolvedDependencyCount
        self.binaryTargets = binaryTargets
        self.binaryTargetSlices = binaryTargetSlices
        self.pluginCount = pluginCount
    }
}

public struct BinaryTargetSlice: Codable, Equatable, Sendable {
    public let platform: String
    public let variant: String?
    public let architectures: [String]

    public init(platform: String, variant: String?, architectures: [String]) {
        self.platform = platform
        self.variant = variant
        self.architectures = architectures
    }
}

public struct PackageAnalysisResult: Sendable {
    public let metadata: PackageMetadata
    public let findings: [Finding]
    public let failures: [AnalysisFailure]

    public init(
        metadata: PackageMetadata,
        findings: [Finding],
        failures: [AnalysisFailure]
    ) {
        self.metadata = metadata
        self.findings = findings
        self.failures = failures
    }
}
