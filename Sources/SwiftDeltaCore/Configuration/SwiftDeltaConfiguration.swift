//===--- SwiftDeltaConfiguration.swift - SwiftDelta ------------------------------------------===//
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

public struct SwiftDeltaConfiguration: Codable, Equatable, Sendable {
    public var defaultWorkspace: String?
    public var defaultProject: String?
    public var defaultScheme: String?
    public var baselineXcodePath: String?
    public var candidateXcodePath: String?
    public var sdkIdentifiers: [String]
    public var activeCompilationConditions: [String]
    public var excludedPaths: [String]
    public var minimumSeverity: Severity
    public var minimumConfidence: Confidence
    public var ciFailureLevel: Severity
    public var outputFormat: ReportFormat

    public init(
        defaultWorkspace: String? = nil,
        defaultProject: String? = nil,
        defaultScheme: String? = nil,
        baselineXcodePath: String? = nil,
        candidateXcodePath: String? = nil,
        sdkIdentifiers: [String] = [],
        activeCompilationConditions: [String] = [],
        excludedPaths: [String] = [],
        minimumSeverity: Severity = .notice,
        minimumConfidence: Confidence = .medium,
        ciFailureLevel: Severity = .error,
        outputFormat: ReportFormat = .terminal
    ) {
        self.defaultWorkspace = defaultWorkspace
        self.defaultProject = defaultProject
        self.defaultScheme = defaultScheme
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

    private enum CodingKeys: String, CodingKey {
        case defaultWorkspace
        case defaultProject
        case defaultScheme
        case baselineXcodePath
        case candidateXcodePath
        case sdkIdentifiers
        case activeCompilationConditions
        case excludedPaths
        case minimumSeverity
        case minimumConfidence
        case ciFailureLevel
        case outputFormat
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        defaultWorkspace = try container.decodeIfPresent(String.self, forKey: .defaultWorkspace)
        defaultProject = try container.decodeIfPresent(String.self, forKey: .defaultProject)
        defaultScheme = try container.decodeIfPresent(String.self, forKey: .defaultScheme)
        baselineXcodePath = try container.decodeIfPresent(
            String.self,
            forKey: .baselineXcodePath
        )
        candidateXcodePath = try container.decodeIfPresent(
            String.self,
            forKey: .candidateXcodePath
        )
        sdkIdentifiers = try container.decodeIfPresent(
            [String].self,
            forKey: .sdkIdentifiers
        ) ?? []
        activeCompilationConditions = try container.decodeIfPresent(
            [String].self,
            forKey: .activeCompilationConditions
        ) ?? []
        excludedPaths = try container.decodeIfPresent([String].self, forKey: .excludedPaths) ?? []
        minimumSeverity =
            try container.decodeIfPresent(Severity.self, forKey: .minimumSeverity) ?? .notice
        minimumConfidence =
            try container.decodeIfPresent(Confidence.self, forKey: .minimumConfidence) ?? .medium
        ciFailureLevel =
            try container.decodeIfPresent(Severity.self, forKey: .ciFailureLevel) ?? .error
        outputFormat =
            try container.decodeIfPresent(ReportFormat.self, forKey: .outputFormat) ?? .terminal
    }

    public func applying(_ overrides: ConfigurationOverrides) throws -> SwiftDeltaConfiguration {
        var copy = self
        if overrides.workspaceWasProvided {
            copy.defaultWorkspace = overrides.workspace
            copy.defaultProject = nil
        }
        if overrides.projectWasProvided {
            copy.defaultProject = overrides.project
            copy.defaultWorkspace = nil
        }
        if let scheme = overrides.scheme {
            copy.defaultScheme = scheme
        }
        if let baselineXcodePath = overrides.baselineXcodePath {
            copy.baselineXcodePath = baselineXcodePath
        }
        if let candidateXcodePath = overrides.candidateXcodePath {
            copy.candidateXcodePath = candidateXcodePath
        }
        if let sdkIdentifiers = overrides.sdkIdentifiers {
            copy.sdkIdentifiers = sdkIdentifiers
        }
        if let activeCompilationConditions = overrides.activeCompilationConditions {
            copy.activeCompilationConditions = activeCompilationConditions
        }
        if let excludedPaths = overrides.excludedPaths {
            copy.excludedPaths = excludedPaths
        }
        if let minimumSeverity = overrides.minimumSeverity {
            copy.minimumSeverity = minimumSeverity
        }
        if let minimumConfidence = overrides.minimumConfidence {
            copy.minimumConfidence = minimumConfidence
        }
        if let ciFailureLevel = overrides.ciFailureLevel {
            copy.ciFailureLevel = ciFailureLevel
        }
        if let outputFormat = overrides.outputFormat {
            copy.outputFormat = outputFormat
        }
        try copy.validate()
        return copy
    }

    public func validate(requireXcodePair: Bool = false) throws {
        if defaultWorkspace != nil, defaultProject != nil {
            throw SwiftDeltaError.invalidConfiguration(
                field: "defaultWorkspace/defaultProject",
                reason: "only one default Xcode container may be selected"
            )
        }
        if requireXcodePair, baselineXcodePath == nil || candidateXcodePath == nil {
            throw SwiftDeltaError.invalidConfiguration(
                field: "baselineXcodePath/candidateXcodePath",
                reason: "both selected Xcode application paths are required for SDK comparison"
            )
        }
        for identifier in sdkIdentifiers where identifier.range(
            of: #"^[A-Za-z0-9_-]+$"#,
            options: .regularExpression
        ) == nil {
            throw SwiftDeltaError.invalidConfiguration(
                field: "sdkIdentifiers",
                reason: "invalid SDK identifier '\(identifier)'"
            )
        }
        try validateUnique(sdkIdentifiers, field: "sdkIdentifiers")
        try validateUnique(activeCompilationConditions, field: "activeCompilationConditions")
        for condition in activeCompilationConditions where condition.range(
            of: #"^[A-Za-z_][A-Za-z0-9_]*$"#,
            options: .regularExpression
        ) == nil {
            throw SwiftDeltaError.invalidConfiguration(
                field: "activeCompilationConditions",
                reason: "invalid Swift compilation condition '\(condition)'"
            )
        }
    }

    private func validateUnique(_ values: [String], field: String) throws {
        var seen = Set<String>()
        if let duplicate = values.first(where: { !seen.insert($0).inserted }) {
            throw SwiftDeltaError.invalidConfiguration(
                field: field,
                reason: "duplicate value '\(duplicate)'"
            )
        }
    }
}
