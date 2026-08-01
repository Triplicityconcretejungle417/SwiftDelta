//===--- TUISettings.swift - SwiftDelta ------------------------------------------===//
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

struct TUISettings: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1

    var formatVersion = Self.currentFormatVersion
    var appearance = TUIAppearanceSettings()
    var interaction = TUIInteractionSettings()
    var workflow = TUIWorkflowSettings()
    var privacy = TUIPrivacySettings()
    var cache = TUICacheSettings()

    init() {}
}

struct TUIAppearanceSettings: Codable, Equatable, Sendable {
    var colorMode: TerminalColorMode?
    var symbolMode: TerminalSymbolMode?
    var highContrast = false
    var reducedMotion = false
}

struct TUIInteractionSettings: Codable, Equatable, Sendable {
    var mouseEnabled = true
    var historyEnabled = false
    var showContextualHelp = true
}

struct TUIPrivacySettings: Codable, Equatable, Sendable {
    var rememberRecentProjects = false
    var retainOperationSummaries = false
}

struct TUICacheSettings: Codable, Equatable, Sendable {
    var maximumAgeDays: Double?
    var maximumSizeMiB: Double?
}

struct TUIWorkflowSettings: Codable, Equatable, Sendable {
    var projectRoot = FileManager.default.currentDirectoryPath
    var configurationPath: String?
    var workspacePath: String?
    var projectPath: String?
    var scheme: String?
    var buildConfiguration: String?
    var destination: String?
    var baselineXcodePath: String?
    var candidateXcodePath: String?
    var sdkIdentifiers: [String] = []
    var activeCompilationConditions: [String] = []
    var excludedPaths: [String] = []
    var minimumSeverity = Severity.notice
    var minimumConfidence = Confidence.medium
    var includeUncertain = false
    var timeout: TimeInterval = 900
    var doctorTimeout: TimeInterval = 60
    var failureLevel = Severity.error
    var allowIncomplete = false
    var progressQuiet = false
    var sdkCachePolicy = SDKSnapshotCachePolicy.use
    var reportFormat = ReportFormat.terminal
    var reportOutputPath: String?
    var repairSourcePaths: [String] = []
    var repairIdentifiers: [String] = []
    var findingIdentifiers: [String] = []
    var repairPlanInputPath: String?
    var repairPlanFormat = RepairPlanOutputFormat.diff
    var repairOutputPath: String?
    /// Retained so existing settings files decode; runtime capability now
    /// determines whether the on-device model stage is available.
    var foundationModelsEnabled = false
    var foundationModelReasoning: FoundationModelReasoningLevel?
    var foundationModelTimeout: TimeInterval = 120
    /// Optional to preserve decoding of settings written before this control
    /// existed. A nil value uses the core default.
    var foundationModelCandidateLimit: Int?
    /// Records how setup values were chosen without changing analysis semantics.
    var setupValueOrigins: [String: TUISetupValueOrigin]?
}

struct TUIHistory: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1

    var formatVersion = Self.currentFormatVersion
    var entries: [TUIHistoryEntry] = []
}

struct TUIHistoryEntry: Codable, Equatable, Sendable {
    let projectPath: String
    let openedAt: Date
    let lastOperation: String?
    let outcome: String?
}
