//===--- RepairModels.swift - SwiftDelta ------------------------------------------===//
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

public enum RepairEvidenceSource: String, Codable, CaseIterable, Sendable {
    case swiftCompilerFixIt
    case clangCompilerFixIt
    case sdkRename
    case mechanicalSignatureChange
    case foundationModels
}

public enum RepairLanguage: String, Codable, CaseIterable, Sendable {
    case swift
    case objectiveC
    case objectiveCpp
    case c
    case cpp
    case cOrObjectiveCHeader
    case cppOrObjectiveCppHeader
}

public enum RepairSafetyClassification: String, Codable, CaseIterable, Sendable {
    case safe
    case reviewRequired
    case suggestionOnly
    case notRepairable
}

public enum RepairVerificationRequirement: String, Codable, Sendable {
    case candidateBuild
    case candidateTypeCheck
}

public struct RepairSourcePosition: Codable, Hashable, Sendable {
    public let line: Int
    public let column: Int
    public let utf8Offset: Int

    public init(line: Int, column: Int, utf8Offset: Int) {
        self.line = line
        self.column = column
        self.utf8Offset = utf8Offset
    }
}

public struct RepairSourceRange: Codable, Hashable, Sendable {
    public let start: RepairSourcePosition
    public let end: RepairSourcePosition

    public init(start: RepairSourcePosition, end: RepairSourcePosition) {
        self.start = start
        self.end = end
    }
}

public struct RepairFileFingerprint: Codable, Hashable, Sendable {
    public static let algorithm = "sha256"

    public let algorithm: String
    public let digest: String
    public let byteCount: Int

    public init(digest: String, byteCount: Int) {
        self.algorithm = Self.algorithm
        self.digest = digest
        self.byteCount = byteCount
    }
}

public struct RepairToolchainEvidence: Codable, Hashable, Sendable {
    public let baseline: SDKInstallationIdentity?
    public let candidate: SDKInstallationIdentity?

    public init(
        baseline: SDKInstallationIdentity? = nil,
        candidate: SDKInstallationIdentity? = nil
    ) {
        self.baseline = baseline
        self.candidate = candidate
    }
}

public struct RepairSymbolEvidence: Codable, Hashable, Sendable {
    public let baselinePreciseIdentifier: String?
    public let candidatePreciseIdentifier: String?
    public let moduleName: String?
    public let baselineDeclaration: String?
    public let candidateDeclaration: String?

    public init(
        baselinePreciseIdentifier: String? = nil,
        candidatePreciseIdentifier: String? = nil,
        moduleName: String? = nil,
        baselineDeclaration: String? = nil,
        candidateDeclaration: String? = nil
    ) {
        self.baselinePreciseIdentifier = baselinePreciseIdentifier
        self.candidatePreciseIdentifier = candidatePreciseIdentifier
        self.moduleName = moduleName
        self.baselineDeclaration = baselineDeclaration
        self.candidateDeclaration = candidateDeclaration
    }
}

public struct RepairCompilerContextEvidence: Codable, Hashable, Sendable {
    public let compilerPath: String
    public let target: String?
    public let moduleName: String?
    public let sdkIdentifier: String
    public let sdkPath: String
    public let destination: String?
    public let diagnosticIdentity: String
    public let evidenceArtifact: String
    public let isTargetAware: Bool

    public init(
        compilerPath: String,
        target: String? = nil,
        moduleName: String? = nil,
        sdkIdentifier: String,
        sdkPath: String,
        destination: String? = nil,
        diagnosticIdentity: String,
        evidenceArtifact: String,
        isTargetAware: Bool
    ) {
        self.compilerPath = compilerPath
        self.target = target
        self.moduleName = moduleName
        self.sdkIdentifier = sdkIdentifier
        self.sdkPath = sdkPath
        self.destination = destination
        self.diagnosticIdentity = diagnosticIdentity
        self.evidenceArtifact = evidenceArtifact
        self.isTargetAware = isTargetAware
    }
}

public struct ProposedRepair: Codable, Hashable, Identifiable, Sendable {
    public var id: String { repairIdentifier }

    public let repairIdentifier: String
    public let relatedFindingIdentifier: String
    public let evidenceSource: RepairEvidenceSource
    public let language: RepairLanguage
    /// Project-relative path. Absolute paths are never stored in a repair plan.
    public let filePath: String
    public let sourceRange: RepairSourceRange
    public let originalText: String
    public let replacementText: String
    public let fileFingerprint: RepairFileFingerprint
    public let confidence: Confidence
    public let safety: RepairSafetyClassification
    public let explanation: String
    public let verificationRequirement: RepairVerificationRequirement
    public let toolchains: RepairToolchainEvidence?
    public let symbols: RepairSymbolEvidence?
    public let compilerContext: RepairCompilerContextEvidence?
    public let generatedBy: String?
    public let provider: String?
    public let execution: String?
    public let hostModelGeneration: String?
    public let reasoningLevel: String?
    public let modelGenerated: Bool?
    public let requiresReview: Bool?

    public init(
        repairIdentifier: String,
        relatedFindingIdentifier: String,
        evidenceSource: RepairEvidenceSource,
        language: RepairLanguage,
        filePath: String,
        sourceRange: RepairSourceRange,
        originalText: String,
        replacementText: String,
        fileFingerprint: RepairFileFingerprint,
        confidence: Confidence,
        safety: RepairSafetyClassification,
        explanation: String,
        verificationRequirement: RepairVerificationRequirement,
        toolchains: RepairToolchainEvidence? = nil,
        symbols: RepairSymbolEvidence? = nil,
        compilerContext: RepairCompilerContextEvidence? = nil,
        generatedBy: String? = nil,
        provider: String? = nil,
        execution: String? = nil,
        hostModelGeneration: String? = nil,
        reasoningLevel: String? = nil,
        modelGenerated: Bool? = nil,
        requiresReview: Bool? = nil
    ) {
        self.repairIdentifier = repairIdentifier
        self.relatedFindingIdentifier = relatedFindingIdentifier
        self.evidenceSource = evidenceSource
        self.language = language
        self.filePath = filePath
        self.sourceRange = sourceRange
        self.originalText = originalText
        self.replacementText = replacementText
        self.fileFingerprint = fileFingerprint
        self.confidence = confidence
        self.safety = safety
        self.explanation = explanation
        self.verificationRequirement = verificationRequirement
        self.toolchains = toolchains
        self.symbols = symbols
        self.compilerContext = compilerContext
        self.generatedBy = generatedBy
        self.provider = provider
        self.execution = execution
        self.hostModelGeneration = hostModelGeneration
        self.reasoningLevel = reasoningLevel
        self.modelGenerated = modelGenerated
        self.requiresReview = requiresReview
    }

    public var isExplicitlyApplicable: Bool {
        safety == .safe
            || (
                evidenceSource == .foundationModels
                    && modelGenerated == true
                    && requiresReview == true
                    && safety == .reviewRequired
            )
    }
}

public enum RepairConflictKind: String, Codable, Sendable {
    case duplicate
    case multipleFindingsSameEdit
    case overlapping
    case contradictory
    case invalidRange
}

public struct RepairConflict: Codable, Hashable, Sendable {
    public let kind: RepairConflictKind
    public let repairIdentifiers: [String]
    public let explanation: String

    public init(
        kind: RepairConflictKind,
        repairIdentifiers: [String],
        explanation: String
    ) {
        self.kind = kind
        self.repairIdentifiers = repairIdentifiers.sorted()
        self.explanation = explanation
    }
}

public struct RepairPlan: Codable, Sendable {
    public static let currentFormatVersion = "3.0"

    public let repairPlanFormatVersion: String
    public let generatedAt: Date
    public let projectRoot: String
    public let repairs: [ProposedRepair]
    public let conflicts: [RepairConflict]
    public let planningFailures: [AnalysisFailure]

    public init(
        generatedAt: Date = Date(),
        projectRoot: String,
        repairs: [ProposedRepair],
        conflicts: [RepairConflict] = [],
        planningFailures: [AnalysisFailure] = []
    ) {
        self.repairPlanFormatVersion = Self.currentFormatVersion
        self.generatedAt = generatedAt
        self.projectRoot = projectRoot
        self.repairs = repairs
        self.conflicts = conflicts
        self.planningFailures = planningFailures
    }
}
