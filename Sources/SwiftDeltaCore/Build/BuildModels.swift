//===--- BuildModels.swift - SwiftDelta ------------------------------------------===//
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

public struct BuildInvocation: Sendable {
    public let xcodePath: String
    public let container: ProjectContainer
    public let scheme: String
    public let configuration: String?
    public let destination: String?
    public let timeout: TimeInterval
    public let sdkIdentifiers: [String]
    public let xcodeIdentity: String?

    public init(
        xcodePath: String,
        container: ProjectContainer,
        scheme: String = "",
        configuration: String? = nil,
        destination: String? = nil,
        timeout: TimeInterval = 900,
        sdkIdentifiers: [String] = [],
        xcodeIdentity: String? = nil
    ) {
        self.xcodePath = xcodePath
        self.container = container
        self.scheme = scheme
        self.configuration = configuration
        self.destination = destination
        self.timeout = timeout
        self.sdkIdentifiers = Array(Set(sdkIdentifiers)).sorted()
        self.xcodeIdentity = xcodeIdentity
    }
}

public struct BuildOutcome: Sendable {
    public let xcodePath: String
    public let exitStatus: Int32
    public let diagnostics: [CompilerDiagnostic]
    public let buildSettings: [BuildSettingsSnapshot]
    public let diagnosticSource: BuildDiagnosticSource

    public init(
        xcodePath: String,
        exitStatus: Int32,
        diagnostics: [CompilerDiagnostic],
        buildSettings: [BuildSettingsSnapshot],
        diagnosticSource: BuildDiagnosticSource = .xcodebuildText
    ) {
        self.xcodePath = xcodePath
        self.exitStatus = exitStatus
        self.diagnostics = diagnostics
        self.buildSettings = buildSettings
        self.diagnosticSource = diagnosticSource
    }

    public var succeeded: Bool {
        exitStatus == 0
    }
}

public enum BuildDiagnosticSource: String, Codable, Sendable {
    case modernXCResult
    case legacyXCResult
    case xcodebuildText
    case swiftBuildText
}

public protocol ProjectBuilding: Sendable {
    func build(
        _ invocation: BuildInvocation,
        cancellation: @escaping @Sendable () -> Bool
    ) throws -> BuildOutcome
}
