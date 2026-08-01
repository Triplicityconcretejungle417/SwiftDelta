//===--- RepairCandidatePresentation.swift - SwiftDelta ------------------------------------------===//
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

/// Runtime-only status used by the interactive repair review workflow.
///
/// This type is intentionally separate from `RepairPlan`: a rejected or
/// unresolved candidate must remain inspectable without becoming an edit in a
/// versioned, applicable repair plan.
public enum RepairCandidateStatus: String, Sendable {
    case ready
    case needsValidation
    case reviewRequired
    case verificationFailed
    case rejected
    case noProposal
}

public struct RepairCandidateEditPresentation: Hashable, Sendable {
    public let operation: String
    public let filePath: String
    public let originalText: String
    public let replacementText: String
    public let sourceRange: RepairSourceRange?

    public init(
        operation: String,
        filePath: String,
        originalText: String,
        replacementText: String,
        sourceRange: RepairSourceRange? = nil
    ) {
        self.operation = operation
        self.filePath = filePath
        self.originalText = originalText
        self.replacementText = replacementText
        self.sourceRange = sourceRange
    }
}

/// One inspectable outcome from repair planning.
///
/// A finding always has at least one presentation, even when it has no source
/// proposal. Model responses that fail later validation are retained here so
/// the user can inspect the attempted edit and the exact rejection reason.
public struct RepairCandidatePresentation: Hashable, Sendable {
    public let candidateIdentifier: String
    public let draftIdentifier: String?
    public let findingStableKey: String
    public let findingIdentifier: String
    public let title: String
    public let location: SourceLocation?
    public let symbol: String?
    public let status: RepairCandidateStatus
    public let repairSource: String
    public let confidence: Confidence?
    public let summary: String
    public let explanation: String
    public let evidence: [String]
    public let risks: [String]
    public let repairIdentifiers: [String]
    public let edits: [RepairCandidateEditPresentation]
    public let verificationMessage: String?
    public let suppliedSource: String?
    public let baselineDeclaration: String?
    public let candidateDeclaration: String?
    public let modelDisposition: String?
    public let validationStage: String?

    public init(
        candidateIdentifier: String,
        draftIdentifier: String? = nil,
        findingStableKey: String,
        findingIdentifier: String,
        title: String,
        location: SourceLocation?,
        symbol: String? = nil,
        status: RepairCandidateStatus,
        repairSource: String,
        confidence: Confidence? = nil,
        summary: String,
        explanation: String,
        evidence: [String] = [],
        risks: [String] = [],
        repairIdentifiers: [String] = [],
        edits: [RepairCandidateEditPresentation] = [],
        verificationMessage: String? = nil,
        suppliedSource: String? = nil,
        baselineDeclaration: String? = nil,
        candidateDeclaration: String? = nil,
        modelDisposition: String? = nil,
        validationStage: String? = nil
    ) {
        self.candidateIdentifier = candidateIdentifier
        self.draftIdentifier = draftIdentifier
        self.findingStableKey = findingStableKey
        self.findingIdentifier = findingIdentifier
        self.title = title
        self.location = location
        self.symbol = symbol
        self.status = status
        self.repairSource = repairSource
        self.confidence = confidence
        self.summary = summary
        self.explanation = explanation
        self.evidence = evidence
        self.risks = risks
        self.repairIdentifiers = repairIdentifiers.sorted()
        self.edits = edits
        self.verificationMessage = verificationMessage
        self.suppliedSource = suppliedSource
        self.baselineDeclaration = baselineDeclaration
        self.candidateDeclaration = candidateDeclaration
        self.modelDisposition = modelDisposition
        self.validationStage = validationStage
    }

    public var isSelectable: Bool {
        status == .ready && !repairIdentifiers.isEmpty
    }

    public func attachingDraftIdentifier(
        _ identifier: String
    ) -> RepairCandidatePresentation {
        RepairCandidatePresentation(
            candidateIdentifier: candidateIdentifier,
            draftIdentifier: identifier,
            findingStableKey: findingStableKey,
            findingIdentifier: findingIdentifier,
            title: title,
            location: location,
            symbol: symbol,
            status: status,
            repairSource: repairSource,
            confidence: confidence,
            summary: summary,
            explanation: explanation,
            evidence: evidence,
            risks: risks,
            repairIdentifiers: repairIdentifiers,
            edits: edits,
            verificationMessage: verificationMessage,
            suppliedSource: suppliedSource,
            baselineDeclaration: baselineDeclaration,
            candidateDeclaration: candidateDeclaration,
            modelDisposition: modelDisposition,
            validationStage: validationStage
        )
    }
}

public enum RepairCandidatePresentationBuilder {
    public static func build(
        findings: [Finding],
        plan: RepairPlan,
        dispositions: [RepairFindingDisposition],
        modelAttempts: [RepairCandidatePresentation] = []
    ) -> [RepairCandidatePresentation] {
        let conflictIDs = Set(plan.conflicts.flatMap(\.repairIdentifiers))
        let findingsByStableKey = Dictionary(
            findings.map { ($0.stableKey, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let findingsByID = Dictionary(
            findings.map { ($0.findingID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let attemptsByStableKey = Dictionary(
            grouping: modelAttempts,
            by: \.findingStableKey
        )
        var values: [RepairCandidatePresentation] = []
        var representedRepairIDs = Set<String>()

        for disposition in dispositions.sorted(
            by: { $0.findingStableKey < $1.findingStableKey }
        ) {
            let finding = findingsByStableKey[disposition.findingStableKey]
                ?? findingsByID[disposition.findingIdentifier]
            let repairs = plan.repairs.filter {
                disposition.repairIdentifiers.contains($0.repairIdentifier)
            }
            if !repairs.isEmpty {
                representedRepairIDs.formUnion(repairs.map(\.repairIdentifier))
                let groups = Dictionary(grouping: repairs) {
                    if $0.modelGenerated != true {
                        return "repair\u{1F}\($0.repairIdentifier)"
                    }
                    return [
                        $0.relatedFindingIdentifier,
                        $0.evidenceSource.rawValue,
                        $0.filePath,
                        $0.explanation,
                        $0.modelGenerated == true ? "model" : "deterministic",
                    ].joined(separator: "\u{1F}")
                }
                for (_, group) in groups.sorted(by: { $0.key < $1.key }) {
                    let sorted = group.sorted {
                        if $0.sourceRange.start.utf8Offset
                            != $1.sourceRange.start.utf8Offset
                        {
                            return $0.sourceRange.start.utf8Offset
                                < $1.sourceRange.start.utf8Offset
                        }
                        return $0.repairIdentifier < $1.repairIdentifier
                    }
                    guard let first = sorted.first else { continue }
                    let conflicts = sorted.contains {
                        conflictIDs.contains($0.repairIdentifier)
                    }
                    let status: RepairCandidateStatus
                    if conflicts {
                        status = .rejected
                    } else if first.evidenceSource == .foundationModels {
                        status = first.safety == .suggestionOnly
                            ? .reviewRequired : .needsValidation
                    } else if sorted.allSatisfy({ $0.safety == .safe }) {
                        status = .ready
                    } else {
                        status = .reviewRequired
                    }
                    values.append(
                        RepairCandidatePresentation(
                            candidateIdentifier: RepairFingerprint.identifier(
                                ["candidate"] + sorted.map(\.repairIdentifier)
                            ),
                            findingStableKey: disposition.findingStableKey,
                            findingIdentifier: disposition.findingIdentifier,
                            title: disposition.title,
                            location: disposition.location,
                            symbol: finding?.sdkEvidence?.fullyQualifiedName,
                            status: status,
                            repairSource: sourceLabel(first.evidenceSource),
                            confidence: first.confidence,
                            summary: changeSummary(sorted),
                            explanation: first.explanation,
                            evidence: evidence(for: first),
                            risks: conflicts
                                ? plan.conflicts.filter {
                                    !$0.repairIdentifiers
                                        .filter(
                                            Set(sorted.map(\.repairIdentifier))
                                                .contains
                                        ).isEmpty
                                }.map(\.explanation)
                                : [],
                            repairIdentifiers: sorted.map(\.repairIdentifier),
                            edits: sorted.map {
                                RepairCandidateEditPresentation(
                                    operation: operation(for: $0),
                                    filePath: $0.filePath,
                                    originalText: $0.originalText,
                                    replacementText: $0.replacementText,
                                    sourceRange: $0.sourceRange
                                )
                            }
                        )
                    )
                }
            }
            values.append(contentsOf: attemptsByStableKey[
                disposition.findingStableKey
            ] ?? [])
            if repairs.isEmpty,
               attemptsByStableKey[disposition.findingStableKey]?.isEmpty
                    != false
            {
                values.append(
                    RepairCandidatePresentation(
                        candidateIdentifier: RepairFingerprint.identifier([
                            "candidate",
                            disposition.findingStableKey,
                            disposition.kind.rawValue,
                            disposition.reason,
                        ]),
                        findingStableKey: disposition.findingStableKey,
                        findingIdentifier: disposition.findingIdentifier,
                        title: disposition.title,
                        location: disposition.location,
                        symbol: finding?.sdkEvidence?.fullyQualifiedName,
                        status: disposition.hasConflict
                            ? .rejected : .noProposal,
                        repairSource: "Analysis",
                        confidence: finding?.confidence,
                        summary: disposition.hasConflict
                            ? "Conflicting source edits" : "No source proposal",
                        explanation: disposition.reason,
                        evidence: findingEvidence(finding),
                        risks: disposition.hasConflict
                            ? [disposition.reason] : []
                    )
                )
            }
        }
        let unrepresented = plan.repairs.filter {
            !representedRepairIDs.contains($0.repairIdentifier)
        }
        let fallbackGroups = Dictionary(
            grouping: unrepresented,
            by: \.relatedFindingIdentifier
        )
        for (findingID, repairs) in fallbackGroups.sorted(
            by: { $0.key < $1.key }
        ) {
            guard let first = repairs.first else { continue }
            let fallback = RepairFindingDisposition(
                findingStableKey: findingID,
                findingIdentifier: findingID,
                title: findingID,
                location: SourceLocation(
                    path: first.filePath,
                    line: first.sourceRange.start.line,
                    column: first.sourceRange.start.column
                ),
                kind: repairs.allSatisfy({ $0.safety == .safe })
                    ? .automaticallySafe : .manualReviewRequired,
                reason: first.explanation,
                repairIdentifiers: repairs.map(\.repairIdentifier)
            )
            values.append(
                contentsOf: build(
                    findings: [],
                    plan: RepairPlan(
                        generatedAt: plan.generatedAt,
                        projectRoot: plan.projectRoot,
                        repairs: repairs,
                        conflicts: plan.conflicts.filter {
                            !$0.repairIdentifiers
                                .filter(
                                    Set(repairs.map(\.repairIdentifier))
                                        .contains
                                ).isEmpty
                        },
                        planningFailures: []
                    ),
                    dispositions: [fallback]
                )
            )
        }
        return values.sorted {
            let left = statusRank($0.status)
            let right = statusRank($1.status)
            if left != right { return left < right }
            let leftPath = $0.location?.path ?? ""
            let rightPath = $1.location?.path ?? ""
            if leftPath != rightPath { return leftPath < rightPath }
            let leftLine = $0.location?.line ?? 0
            let rightLine = $1.location?.line ?? 0
            if leftLine != rightLine { return leftLine < rightLine }
            return $0.candidateIdentifier < $1.candidateIdentifier
        }
    }

    private static func statusRank(_ value: RepairCandidateStatus) -> Int {
        switch value {
        case .ready: 0
        case .needsValidation: 1
        case .reviewRequired: 2
        case .verificationFailed: 3
        case .rejected: 4
        case .noProposal: 5
        }
    }

    private static func sourceLabel(_ source: RepairEvidenceSource) -> String {
        switch source {
        case .swiftCompilerFixIt, .clangCompilerFixIt:
            "Compiler Fix-it"
        case .sdkRename:
            "SDK rename"
        case .mechanicalSignatureChange:
            "Mechanical"
        case .foundationModels:
            "Apple Foundation Models"
        }
    }

    private static func operation(for repair: ProposedRepair) -> String {
        if repair.originalText.isEmpty { return "insert" }
        if repair.replacementText.isEmpty { return "delete" }
        return "replace"
    }

    private static func changeSummary(_ repairs: [ProposedRepair]) -> String {
        guard repairs.count != 1 else {
            return "\(operation(for: repairs[0]).capitalized) "
                + "\(repairs[0].sourceRange.start.line):"
                + "\(repairs[0].sourceRange.start.column)"
        }
        return "\(repairs.count) coordinated edits"
    }

    private static func evidence(for repair: ProposedRepair) -> [String] {
        var result = [repair.evidenceSource.rawValue]
        if let identity = repair.compilerContext?.diagnosticIdentity {
            result.append("Diagnostic \(identity)")
        }
        if let identity = repair.symbols?.baselinePreciseIdentifier {
            result.append("Baseline symbol \(identity)")
        }
        if let identity = repair.symbols?.candidatePreciseIdentifier {
            result.append("Candidate symbol \(identity)")
        }
        if let module = repair.symbols?.moduleName {
            result.append("Module \(module)")
        }
        return result
    }

    private static func findingEvidence(_ finding: Finding?) -> [String] {
        guard let finding else { return [] }
        var values = [
            "\(finding.origin.rawValue) evidence",
            "\(finding.category.rawValue) finding",
        ]
        if let symbol = finding.sdkEvidence?.preciseIdentifier {
            values.append("Symbol \(symbol)")
        }
        return values
    }
}
