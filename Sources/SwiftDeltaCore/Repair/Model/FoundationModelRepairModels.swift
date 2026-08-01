//===--- FoundationModelRepairModels.swift - SwiftDelta ------------------------------------------===//
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

/// Configurable reasoning levels exposed by capable macOS 27 models.
public enum FoundationModelReasoningLevel: String, Codable, CaseIterable, Sendable {
    case light
    case moderate
    case deep
}

enum FoundationModelHostGeneration: String, Codable, CaseIterable, Sendable {
    case macOS26_0To26_3 = "macOS 26.0–26.3"
    case macOS26_4 = "macOS 26.4"
    case macOS27 = "macOS 27"
}

/// Explicit controls for one bounded Foundation Models repair request.
public struct FoundationModelRepairOptions: Hashable, Sendable {
    public static let defaultMaximumCandidates = 25
    public static let hardMaximumCandidates = 100

    public let reasoningLevel: FoundationModelReasoningLevel?
    public let timeout: TimeInterval
    public let maximumCandidates: Int

    /// Creates controls for one bounded, local model-planning stage.
    public init(
        reasoningLevel: FoundationModelReasoningLevel? = nil,
        timeout: TimeInterval = 120,
        maximumCandidates: Int = Self.defaultMaximumCandidates
    ) {
        self.reasoningLevel = reasoningLevel
        self.timeout = timeout
        self.maximumCandidates = min(
            max(1, maximumCandidates),
            Self.hardMaximumCandidates
        )
    }
}

enum FoundationModelRiskLevel: String, Codable, CaseIterable, Sendable {
    case low
    case medium
    case high
}

enum ModelRepairDisposition: String, Codable, CaseIterable, Sendable {
    case repairable
    case reviewRequired
    case notRepairable
}

enum ModelRepairConfidence: String, Codable, CaseIterable, Sendable {
    case low
    case medium
    case high
}

enum ModelRepairEditOperation: String, Codable, CaseIterable, Sendable {
    case replace
    case insertBefore
    case insertAfter
    case delete
}

struct ModelRepairEdit: Codable, Hashable, Sendable {
    let operation: ModelRepairEditOperation
    let sourceFileIdentity: String
    let originalAnchor: String
    let source: String

    init(
        operation: ModelRepairEditOperation,
        sourceFileIdentity: String,
        originalAnchor: String,
        source: String
    ) {
        self.operation = operation
        self.sourceFileIdentity = sourceFileIdentity
        self.originalAnchor = originalAnchor
        self.source = source
    }
}

struct ModelRepairProposal: Codable, Hashable, Sendable {
    let disposition: ModelRepairDisposition
    let sourceFileIdentity: String
    let sourceLanguage: RepairLanguage
    let edits: [ModelRepairEdit]
    let explanation: String
    let confidence: ModelRepairConfidence
    let evidenceUsed: [String]
    let assumptions: [String]
    let unresolvedRisks: [String]

    init(
        disposition: ModelRepairDisposition,
        sourceFileIdentity: String,
        sourceLanguage: RepairLanguage,
        edits: [ModelRepairEdit],
        explanation: String,
        confidence: ModelRepairConfidence,
        evidenceUsed: [String],
        assumptions: [String],
        unresolvedRisks: [String]
    ) {
        self.disposition = disposition
        self.sourceFileIdentity = sourceFileIdentity
        self.sourceLanguage = sourceLanguage
        self.edits = edits
        self.explanation = explanation
        self.confidence = confidence
        self.evidenceUsed = evidenceUsed
        self.assumptions = assumptions
        self.unresolvedRisks = unresolvedRisks
    }

    /// Compatibility initializer retained for deterministic provider fixtures.
    init(
        disposition: ModelRepairDisposition,
        sourceFileIdentity: String,
        originalFragment: String,
        proposedReplacement: String,
        explanation: String,
        confidence: ModelRepairConfidence,
        evidenceUsed: [String],
        assumptions: [String],
        unresolvedRisks: [String],
        sourceLanguage: RepairLanguage = .swift
    ) {
        self.init(
            disposition: disposition,
            sourceFileIdentity: sourceFileIdentity,
            sourceLanguage: sourceLanguage,
            edits: originalFragment.isEmpty
                ? []
                : [
                    ModelRepairEdit(
                        operation: .replace,
                        sourceFileIdentity: sourceFileIdentity,
                        originalAnchor: originalFragment,
                        source: proposedReplacement
                    ),
                ],
            explanation: explanation,
            confidence: confidence,
            evidenceUsed: evidenceUsed,
            assumptions: assumptions,
            unresolvedRisks: unresolvedRisks
        )
    }

    var originalFragment: String {
        edits.first?.originalAnchor ?? ""
    }

    var proposedReplacement: String {
        edits.first?.source ?? ""
    }

    var canRepair: Bool {
        disposition != .notRepairable
    }

    var replacementFragment: String {
        proposedReplacement
    }

    var conciseRationale: String {
        explanation
    }

    var evidenceReferences: [String] {
        evidenceUsed
    }

    var requiresReview: Bool {
        true
    }

    var riskLevel: FoundationModelRiskLevel {
        switch confidence {
        case .high:
            disposition == .repairable ? .low : .medium
        case .medium:
            .medium
        case .low:
            .high
        }
    }
}

enum FoundationModelRepairEvidenceLevel: Int, Hashable, Sendable {
    case sdkRisk
    case diagnosticBacked
}

struct RepairContext: Hashable, Sendable {
    let relatedFindingIdentifier: String
    let findingStableKey: String
    let findingSeverity: Severity
    let userSelected: Bool
    let evidenceLevel: FoundationModelRepairEvidenceLevel
    let diagnostic: CompilerDiagnostic?
    let diagnosticIdentifier: String?
    let filePath: String
    let language: RepairLanguage
    let sourceFragment: String
    let enclosingDeclaration: String
    let allowedEditingRange: RepairSourceRange
    let sourceFingerprint: RepairFileFingerprint
    let resolvedSymbolIdentity: String
    let candidateSymbolIdentity: String
    let baselineSDKDeclaration: String
    let candidateSDKDeclaration: String
    let sdkDifferences: [String]
    let compilerFixItEvidence: [String]
    let deterministicRepairCandidates: [String]
    let restrictions: [String]
    let toolchains: RepairToolchainEvidence
    let symbols: RepairSymbolEvidence
    let compilerContext: RepairCompilerContextEvidence

    func addingRestriction(_ restriction: String) -> RepairContext {
        RepairContext(
            relatedFindingIdentifier: relatedFindingIdentifier,
            findingStableKey: findingStableKey,
            findingSeverity: findingSeverity,
            userSelected: userSelected,
            evidenceLevel: evidenceLevel,
            diagnostic: diagnostic,
            diagnosticIdentifier: diagnosticIdentifier,
            filePath: filePath,
            language: language,
            sourceFragment: sourceFragment,
            enclosingDeclaration: enclosingDeclaration,
            allowedEditingRange: allowedEditingRange,
            sourceFingerprint: sourceFingerprint,
            resolvedSymbolIdentity: resolvedSymbolIdentity,
            candidateSymbolIdentity: candidateSymbolIdentity,
            baselineSDKDeclaration: baselineSDKDeclaration,
            candidateSDKDeclaration: candidateSDKDeclaration,
            sdkDifferences: sdkDifferences,
            compilerFixItEvidence: compilerFixItEvidence,
            deterministicRepairCandidates: deterministicRepairCandidates,
            restrictions: restrictions + [restriction],
            toolchains: toolchains,
            symbols: symbols,
            compilerContext: compilerContext
        )
    }
}

/// Runtime accounting for the bounded on-device repair stage.
///
/// This is intentionally separate from the versioned repair-plan schema.
public struct FoundationModelPlanningSummary: Hashable, Sendable {
    public let findingsConsidered: Int
    public let processed: Int
    public let skipped: Int
    public let deduplicated: Int
    public let deferredByLimit: Int
    public let rejected: Int
    public let drafted: Int
    public let convertedIntoRepairs: Int
    public let unavailable: Int
    public let timedOut: Int
    public let cancelled: Int

    public init(
        findingsConsidered: Int,
        processed: Int,
        skipped: Int,
        deduplicated: Int,
        deferredByLimit: Int,
        rejected: Int,
        drafted: Int = 0,
        convertedIntoRepairs: Int,
        unavailable: Int = 0,
        timedOut: Int = 0,
        cancelled: Int = 0
    ) {
        self.findingsConsidered = findingsConsidered
        self.processed = processed
        self.skipped = skipped
        self.deduplicated = deduplicated
        self.deferredByLimit = deferredByLimit
        self.rejected = rejected
        self.drafted = drafted
        self.convertedIntoRepairs = convertedIntoRepairs
        self.unavailable = unavailable
        self.timedOut = timedOut
        self.cancelled = cancelled
    }

    static let empty = FoundationModelPlanningSummary(
        findingsConsidered: 0,
        processed: 0,
        skipped: 0,
        deduplicated: 0,
        deferredByLimit: 0,
        rejected: 0,
        convertedIntoRepairs: 0
    )
}

enum FoundationModelAvailabilityState: Hashable, Sendable {
    case available
    case unsupportedOperatingSystem
    case unsupportedHardware
    case appleIntelligenceDisabled
    case modelNotReady
    case unsupportedLanguageOrLocale
    case unsupportedCapability(String)
}

/// A runtime-only view of the local Apple Foundation Models capability.
///
/// SwiftDelta never treats this status as analysis evidence. It controls only
/// whether the optional on-device repair stage is available in the TUI.
public struct OnDeviceFoundationModelStatus: Hashable, Sendable {
    public enum Availability: String, Hashable, Sendable {
        case available
        case unavailable
    }

    public let availability: Availability
    public let hostModelGeneration: String?
    public let reasoningLevel: String

    public init(
        availability: Availability,
        hostModelGeneration: String?,
        reasoningLevel: String
    ) {
        self.availability = availability
        self.hostModelGeneration = hostModelGeneration
        self.reasoningLevel = reasoningLevel
    }

    public var isAvailable: Bool {
        availability == .available
    }

    public static func current(
        reasoningLevel: FoundationModelReasoningLevel? = nil
    ) -> OnDeviceFoundationModelStatus {
        let status = AppleFoundationModelRepairProvider().status(
            options: FoundationModelRepairOptions(
                reasoningLevel: reasoningLevel
            )
        )
        return OnDeviceFoundationModelStatus(
            availability: status.availability == .available
                ? .available : .unavailable,
            hostModelGeneration: status.generation?.rawValue,
            reasoningLevel: status.reasoningLevel
        )
    }

    public static let unavailable = OnDeviceFoundationModelStatus(
        availability: .unavailable,
        hostModelGeneration: nil,
        reasoningLevel: "unsupported"
    )
}

struct FoundationModelProviderStatus: Hashable, Sendable {
    let availability: FoundationModelAvailabilityState
    let generation: FoundationModelHostGeneration?
    let reasoningLevel: String
    let supportsTokenCounting: Bool
}

struct FoundationModelContextBudget: Hashable, Sendable {
    static let responseTokenAllowance = 1_536
    static let guidedSchemaTokenAllowance = 768

    static var totalReserve: Int {
        responseTokenAllowance + guidedSchemaTokenAllowance
    }

    let tokenCount: Int
    let contextSize: Int
}

protocol FoundationModelRepairProviding: Sendable {
    func status(
        options: FoundationModelRepairOptions
    ) -> FoundationModelProviderStatus

    func contextBudget(
        for context: RepairContext,
        options: FoundationModelRepairOptions,
        cancellation: @escaping @Sendable () -> Bool
    ) throws -> FoundationModelContextBudget?

    func propose(
        for context: RepairContext,
        options: FoundationModelRepairOptions,
        cancellation: @escaping @Sendable () -> Bool
    ) throws -> (ModelRepairProposal, FoundationModelProviderStatus)
}

enum FoundationModelRepairError: LocalizedError, Sendable {
    case unavailable(FoundationModelAvailabilityState)
    case unsupportedReasoning(
        requested: FoundationModelReasoningLevel,
        generation: FoundationModelHostGeneration
    )
    case contextSizeExceeded(tokenCount: Int?, contextSize: Int?)
    case guardrailRejected
    case unsupportedCapability(String)
    case unsupportedLanguageOrLocale
    case concurrentSessionUse
    case cancelled
    case timedOut(TimeInterval)
    case generationFailed(String)
    case invalidStructuredOutput(String)
    case invalidProposal(String)

    var isRecoverableGenerationFailure: Bool {
        switch self {
        case .generationFailed, .invalidStructuredOutput,
             .concurrentSessionUse:
            true
        case .unavailable, .unsupportedReasoning, .contextSizeExceeded,
             .guardrailRejected, .unsupportedCapability,
             .unsupportedLanguageOrLocale, .cancelled, .timedOut,
             .invalidProposal:
            false
        }
    }

    var errorDescription: String? {
        switch self {
        case let .unavailable(state):
            switch state {
            case .available:
                "Apple Foundation Models is available."
            case .unsupportedOperatingSystem:
                "Apple Foundation Models repair requires macOS 26 or later."
            case .unsupportedHardware:
                "Apple Foundation Models is unavailable because this Mac is not eligible."
            case .appleIntelligenceDisabled:
                "Apple Foundation Models is unavailable because Apple Intelligence is disabled."
            case .modelNotReady:
                "Apple Foundation Models is not ready. Allow the system model to finish preparing and retry."
            case .unsupportedLanguageOrLocale:
                "Apple Foundation Models does not support the current language or locale."
            case let .unsupportedCapability(capability):
                "The on-device Apple Foundation Models system model does not support \(capability)."
            }
        case let .unsupportedReasoning(requested, generation):
            "Reasoning level \(requested.rawValue) is unavailable for \(generation.rawValue)."
        case let .contextSizeExceeded(tokenCount, contextSize):
            if let tokenCount, let contextSize {
                "The focused repair request needs at least \(tokenCount) tokens, which "
                    + "meets or exceeds the \(contextSize)-token model context."
            } else {
                "The focused repair context exceeds the model context."
            }
        case .guardrailRejected:
            "Apple Foundation Models rejected the repair request under its guardrails."
        case let .unsupportedCapability(capability):
            "The on-device Apple Foundation Models system model does not support \(capability)."
        case .unsupportedLanguageOrLocale:
            "Apple Foundation Models does not support the current language or locale."
        case .concurrentSessionUse:
            "The Apple Foundation Models session was already processing another request."
        case .cancelled:
            "Apple Foundation Models repair generation was cancelled."
        case let .timedOut(timeout):
            "Apple Foundation Models repair generation exceeded the \(Int(timeout))-second timeout."
        case let .generationFailed(reason):
            "Apple Foundation Models could not generate a repair proposal: \(reason). "
                + "The finding remains unchanged; check model availability and retry."
        case let .invalidStructuredOutput(reason):
            "Apple Foundation Models returned invalid structured output: \(reason)"
        case let .invalidProposal(reason):
            "Apple Foundation Models proposal was rejected: \(reason)"
        }
    }
}

extension FoundationModelHostGeneration {
    static func detect(
        _ version: OperatingSystemVersion
    ) -> FoundationModelHostGeneration? {
        guard version.majorVersion >= 26 else {
            return nil
        }
        if version.majorVersion >= 27 {
            return .macOS27
        }
        if version.minorVersion >= 4 {
            return .macOS26_4
        }
        return .macOS26_0To26_3
    }
}

enum FoundationModelReasoningResolver {
    static func resolve(
        generation: FoundationModelHostGeneration,
        supportsReasoning: Bool,
        requested: FoundationModelReasoningLevel?
    ) throws -> String {
        guard generation == .macOS27 else {
            if let requested {
                throw FoundationModelRepairError.unsupportedReasoning(
                    requested: requested,
                    generation: generation
                )
            }
            return "unsupported"
        }
        guard supportsReasoning else {
            if requested != nil {
                throw FoundationModelRepairError.unsupportedCapability(
                    "configurable reasoning"
                )
            }
            return "unsupported"
        }
        return (requested ?? .deep).rawValue
    }
}
