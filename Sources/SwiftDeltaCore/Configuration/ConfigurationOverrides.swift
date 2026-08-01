//===--- ConfigurationOverrides.swift - SwiftDelta ------------------------------------------===//
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

public struct ConfigurationOverrides: Sendable {
    public var workspace: String?
    public var project: String?
    public var workspaceWasProvided: Bool
    public var projectWasProvided: Bool
    public var scheme: String?
    public var baselineXcodePath: String?
    public var candidateXcodePath: String?
    public var sdkIdentifiers: [String]?
    public var activeCompilationConditions: [String]?
    public var excludedPaths: [String]?
    public var minimumSeverity: Severity?
    public var minimumConfidence: Confidence?
    public var ciFailureLevel: Severity?
    public var outputFormat: ReportFormat?

    public init(
        workspace: String? = nil,
        project: String? = nil,
        workspaceWasProvided: Bool = false,
        projectWasProvided: Bool = false,
        scheme: String? = nil,
        baselineXcodePath: String? = nil,
        candidateXcodePath: String? = nil,
        sdkIdentifiers: [String]? = nil,
        activeCompilationConditions: [String]? = nil,
        excludedPaths: [String]? = nil,
        minimumSeverity: Severity? = nil,
        minimumConfidence: Confidence? = nil,
        ciFailureLevel: Severity? = nil,
        outputFormat: ReportFormat? = nil
    ) {
        self.workspace = workspace
        self.project = project
        self.workspaceWasProvided = workspaceWasProvided
        self.projectWasProvided = projectWasProvided
        self.scheme = scheme
        self.baselineXcodePath = baselineXcodePath
        self.candidateXcodePath = candidateXcodePath
        self.sdkIdentifiers = sdkIdentifiers
        self.activeCompilationConditions = activeCompilationConditions
        self.excludedPaths = excludedPaths
        self.minimumSeverity = minimumSeverity
        self.minimumConfidence = minimumConfidence
        self.ciFailureLevel = ciFailureLevel
        self.outputFormat = outputFormat
    }
}
