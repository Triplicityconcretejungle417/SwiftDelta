//===--- RepairDraft.swift - SwiftDelta ------------------------------------------===//
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
import SwiftParser
import SwiftSyntax

public enum RepairDraftEditOperation: String, Hashable, Sendable {
    case replace
    case insertBefore
    case insertAfter
    case delete
}

public enum RepairDraftIssueStage: String, Hashable, Sendable {
    case generationFailure
    case incompleteDraft
    case sourceAnchor
    case syntax
    case evidenceMismatch
    case ambiguousEdit
    case verification
    case hardSafetyRejection
    case conflict
}

public struct RepairDraftIssue: Hashable, Sendable {
    public let stage: RepairDraftIssueStage
    public let message: String

    public init(stage: RepairDraftIssueStage, message: String) {
        self.stage = stage
        self.message = message
    }
}

public struct RepairDraftEdit: Hashable, Sendable {
    public let operation: RepairDraftEditOperation
    public let sourceFileIdentity: String
    public let originalAnchor: String
    public let proposedSource: String

    public init(
        operation: RepairDraftEditOperation,
        sourceFileIdentity: String,
        originalAnchor: String,
        proposedSource: String
    ) {
        self.operation = operation
        self.sourceFileIdentity = sourceFileIdentity
        self.originalAnchor = originalAnchor
        self.proposedSource = proposedSource
    }
}

/// A model-origin source proposal that has not yet passed isolated validation.
///
/// Drafts are runtime state and do not alter the versioned repair-plan schema.
/// They retain enough trusted project and SDK context to normalize user-edited
/// anchors locally without treating model-provided offsets as evidence.
public struct RepairDraft: Hashable, Sendable {
    public let draftIdentifier: String
    public let findingStableKey: String
    public let findingIdentifier: String
    public let findingTitle: String
    public let findingSeverity: Severity
    public let sourceFile: String
    public let sourceLanguage: RepairLanguage
    public let location: SourceLocation?
    public let symbol: String?
    public let edits: [RepairDraftEdit]
    public let explanation: String
    public let evidence: [String]
    public let assumptions: [String]
    public let risks: [String]
    public let initialIssues: [RepairDraftIssue]
    public let sourceFragment: String
    public let enclosingDeclaration: String
    public let allowedEditingRange: RepairSourceRange
    public let sourceFingerprint: RepairFileFingerprint
    public let diagnostic: CompilerDiagnostic?
    public let diagnosticIdentifier: String?
    public let evidenceLevelIsDiagnosticBacked: Bool
    public let resolvedSymbolIdentity: String
    public let candidateSymbolIdentity: String
    public let baselineSDKDeclaration: String
    public let candidateSDKDeclaration: String
    public let sdkDifferences: [String]
    public let compilerFixItEvidence: [String]
    public let deterministicRepairCandidates: [String]
    public let toolchains: RepairToolchainEvidence
    public let symbols: RepairSymbolEvidence
    public let compilerContext: RepairCompilerContextEvidence
    public let modelIdentity: String
    public let hostModelGeneration: String
    public let reasoningLevel: String
    public let confidence: Confidence

    public init(
        draftIdentifier: String,
        findingStableKey: String,
        findingIdentifier: String,
        findingTitle: String,
        findingSeverity: Severity,
        sourceFile: String,
        sourceLanguage: RepairLanguage,
        location: SourceLocation?,
        symbol: String?,
        edits: [RepairDraftEdit],
        explanation: String,
        evidence: [String],
        assumptions: [String],
        risks: [String],
        initialIssues: [RepairDraftIssue],
        sourceFragment: String,
        enclosingDeclaration: String,
        allowedEditingRange: RepairSourceRange,
        sourceFingerprint: RepairFileFingerprint,
        diagnostic: CompilerDiagnostic?,
        diagnosticIdentifier: String?,
        evidenceLevelIsDiagnosticBacked: Bool,
        resolvedSymbolIdentity: String,
        candidateSymbolIdentity: String,
        baselineSDKDeclaration: String,
        candidateSDKDeclaration: String,
        sdkDifferences: [String],
        compilerFixItEvidence: [String],
        deterministicRepairCandidates: [String],
        toolchains: RepairToolchainEvidence,
        symbols: RepairSymbolEvidence,
        compilerContext: RepairCompilerContextEvidence,
        modelIdentity: String = "Apple Foundation Models",
        hostModelGeneration: String,
        reasoningLevel: String,
        confidence: Confidence
    ) {
        self.draftIdentifier = draftIdentifier
        self.findingStableKey = findingStableKey
        self.findingIdentifier = findingIdentifier
        self.findingTitle = findingTitle
        self.findingSeverity = findingSeverity
        self.sourceFile = sourceFile
        self.sourceLanguage = sourceLanguage
        self.location = location
        self.symbol = symbol
        self.edits = edits
        self.explanation = explanation
        self.evidence = evidence
        self.assumptions = assumptions
        self.risks = risks
        self.initialIssues = initialIssues
        self.sourceFragment = sourceFragment
        self.enclosingDeclaration = enclosingDeclaration
        self.allowedEditingRange = allowedEditingRange
        self.sourceFingerprint = sourceFingerprint
        self.diagnostic = diagnostic
        self.diagnosticIdentifier = diagnosticIdentifier
        self.evidenceLevelIsDiagnosticBacked =
            evidenceLevelIsDiagnosticBacked
        self.resolvedSymbolIdentity = resolvedSymbolIdentity
        self.candidateSymbolIdentity = candidateSymbolIdentity
        self.baselineSDKDeclaration = baselineSDKDeclaration
        self.candidateSDKDeclaration = candidateSDKDeclaration
        self.sdkDifferences = sdkDifferences
        self.compilerFixItEvidence = compilerFixItEvidence
        self.deterministicRepairCandidates =
            deterministicRepairCandidates
        self.toolchains = toolchains
        self.symbols = symbols
        self.compilerContext = compilerContext
        self.modelIdentity = modelIdentity
        self.hostModelGeneration = hostModelGeneration
        self.reasoningLevel = reasoningLevel
        self.confidence = confidence
    }

    public func replacingEdits(
        _ edits: [RepairDraftEdit],
        issues: [RepairDraftIssue] = []
    ) -> RepairDraft {
        RepairDraft(
            draftIdentifier: draftIdentifier,
            findingStableKey: findingStableKey,
            findingIdentifier: findingIdentifier,
            findingTitle: findingTitle,
            findingSeverity: findingSeverity,
            sourceFile: sourceFile,
            sourceLanguage: sourceLanguage,
            location: location,
            symbol: symbol,
            edits: edits,
            explanation: explanation,
            evidence: evidence,
            assumptions: assumptions,
            risks: risks,
            initialIssues: issues,
            sourceFragment: sourceFragment,
            enclosingDeclaration: enclosingDeclaration,
            allowedEditingRange: allowedEditingRange,
            sourceFingerprint: sourceFingerprint,
            diagnostic: diagnostic,
            diagnosticIdentifier: diagnosticIdentifier,
            evidenceLevelIsDiagnosticBacked:
                evidenceLevelIsDiagnosticBacked,
            resolvedSymbolIdentity: resolvedSymbolIdentity,
            candidateSymbolIdentity: candidateSymbolIdentity,
            baselineSDKDeclaration: baselineSDKDeclaration,
            candidateSDKDeclaration: candidateSDKDeclaration,
            sdkDifferences: sdkDifferences,
            compilerFixItEvidence: compilerFixItEvidence,
            deterministicRepairCandidates:
                deterministicRepairCandidates,
            toolchains: toolchains,
            symbols: symbols,
            compilerContext: compilerContext,
            modelIdentity: modelIdentity,
            hostModelGeneration: hostModelGeneration,
            reasoningLevel: reasoningLevel,
            confidence: confidence
        )
    }
}

enum FoundationModelRepairDraftBuilder {
    static func build(
        proposal: ModelRepairProposal,
        context: RepairContext,
        status: FoundationModelProviderStatus,
        validationError: Error? = nil
    ) throws -> RepairDraft? {
        guard proposal.edits.contains(where: {
            !$0.originalAnchor.isEmpty || !$0.source.isEmpty
        }) else {
            return nil
        }
        var issues: [RepairDraftIssue] = []
        if proposal.sourceFileIdentity != context.filePath {
            try validateReturnedPath(
                proposal.sourceFileIdentity,
                expected: context.filePath
            )
            issues.append(
                RepairDraftIssue(
                    stage: .evidenceMismatch,
                    message:
                        "The model returned a different file identity; "
                        + "the draft was constrained to the analyzed source file."
                )
            )
        }
        if proposal.sourceLanguage != context.language {
            issues.append(
                RepairDraftIssue(
                    stage: .evidenceMismatch,
                    message:
                        "The returned language did not match the analyzed "
                        + "source language and was normalized."
                )
            )
        }
        let edits = try proposal.edits.map { edit in
            if edit.sourceFileIdentity != context.filePath {
                try validateReturnedPath(
                    edit.sourceFileIdentity,
                    expected: context.filePath
                )
            }
            return RepairDraftEdit(
                operation: RepairDraftEditOperation(
                    rawValue: edit.operation.rawValue
                ) ?? .replace,
                sourceFileIdentity: context.filePath,
                originalAnchor: edit.originalAnchor,
                proposedSource: edit.source
            )
        }
        for edit in edits {
            if edit.originalAnchor.isEmpty {
                issues.append(
                    RepairDraftIssue(
                        stage: .incompleteDraft,
                        message:
                            "An edit has no source anchor and must be corrected "
                            + "before validation."
                    )
                )
            }
            if edit.operation != .delete, edit.proposedSource.isEmpty {
                issues.append(
                    RepairDraftIssue(
                        stage: .incompleteDraft,
                        message:
                            "An edit has no proposed source and must be "
                            + "completed before validation."
                    )
                )
            }
        }
        if let validationError {
            issues.append(issue(for: validationError))
        }
        let confidence: Confidence = switch proposal.confidence {
        case .low: .low
        case .medium: .medium
        case .high: .high
        }
        let generation = status.generation?.rawValue ?? "unsupported"
        return RepairDraft(
            draftIdentifier: RepairFingerprint.identifier(
                [
                    "foundation-model-draft",
                    context.findingStableKey,
                    context.filePath,
                    generation,
                    status.reasoningLevel,
                ] + edits.flatMap {
                    [
                        $0.operation.rawValue,
                        $0.originalAnchor,
                        $0.proposedSource,
                    ]
                }
            ),
            findingStableKey: context.findingStableKey,
            findingIdentifier: context.relatedFindingIdentifier,
            findingTitle: context.diagnostic?.message
                ?? context.sdkDifferences.first
                ?? "SDK compatibility risk",
            findingSeverity: context.findingSeverity,
            sourceFile: context.filePath,
            sourceLanguage: context.language,
            location: context.diagnostic?.location
                ?? SourceLocation(
                    path: context.filePath,
                    line: context.allowedEditingRange.start.line,
                    column: context.allowedEditingRange.start.column
                ),
            symbol: context.symbols.baselinePreciseIdentifier
                ?? context.resolvedSymbolIdentity,
            edits: edits,
            explanation: proposal.explanation,
            evidence: proposal.evidenceUsed,
            assumptions: proposal.assumptions,
            risks: proposal.unresolvedRisks,
            initialIssues: unique(issues),
            sourceFragment: context.sourceFragment,
            enclosingDeclaration: context.enclosingDeclaration,
            allowedEditingRange: context.allowedEditingRange,
            sourceFingerprint: context.sourceFingerprint,
            diagnostic: context.diagnostic,
            diagnosticIdentifier: context.diagnosticIdentifier,
            evidenceLevelIsDiagnosticBacked:
                context.evidenceLevel == .diagnosticBacked,
            resolvedSymbolIdentity: context.resolvedSymbolIdentity,
            candidateSymbolIdentity: context.candidateSymbolIdentity,
            baselineSDKDeclaration: context.baselineSDKDeclaration,
            candidateSDKDeclaration: context.candidateSDKDeclaration,
            sdkDifferences: context.sdkDifferences,
            compilerFixItEvidence: context.compilerFixItEvidence,
            deterministicRepairCandidates:
                context.deterministicRepairCandidates,
            toolchains: context.toolchains,
            symbols: context.symbols,
            compilerContext: context.compilerContext,
            hostModelGeneration: generation,
            reasoningLevel: status.reasoningLevel,
            confidence: confidence
        )
    }

    private static func validateReturnedPath(
        _ value: String,
        expected: String
    ) throws {
        let path = NSString(string: value)
        let components = path.pathComponents
        let protectedNames: Set<String> = [
            "Package.swift", "Package.resolved", "project.pbxproj",
            "DerivedData", ".build", ".git",
        ]
        guard !path.isAbsolutePath,
              !components.contains(".."),
              !components.contains(where: protectedNames.contains),
              !value.hasSuffix(".xcworkspace"),
              !value.hasSuffix(".xcodeproj")
        else {
            throw FoundationModelRepairError.invalidProposal(
                "the response names a protected or escaping source path"
            )
        }
        _ = expected
    }

    private static func issue(for error: Error) -> RepairDraftIssue {
        let message = error.localizedDescription
        let lower = message.lowercased()
        if lower.contains("ambiguous") {
            return RepairDraftIssue(stage: .ambiguousEdit, message: message)
        }
        if lower.contains("anchor") || lower.contains("permitted source") {
            return RepairDraftIssue(stage: .sourceAnchor, message: message)
        }
        if lower.contains("parse") || lower.contains("syntax")
            || lower.contains("delimiter")
        {
            return RepairDraftIssue(stage: .syntax, message: message)
        }
        if lower.contains("overlap") || lower.contains("contradict") {
            return RepairDraftIssue(stage: .conflict, message: message)
        }
        if lower.contains("protected") || lower.contains("outside") {
            return RepairDraftIssue(
                stage: .hardSafetyRejection,
                message: message
            )
        }
        return RepairDraftIssue(stage: .evidenceMismatch, message: message)
    }

    private static func unique(
        _ issues: [RepairDraftIssue]
    ) -> [RepairDraftIssue] {
        var seen = Set<RepairDraftIssue>()
        return issues.filter { seen.insert($0).inserted }
    }
}

public enum RepairDraftNormalizer {
    public static func normalize(
        _ draft: RepairDraft,
        projectRoot: URL
    ) throws -> [ProposedRepair] {
        let proposalConfidence: ModelRepairConfidence
        switch draft.confidence {
        case .low:
            proposalConfidence = .low
        case .medium:
            proposalConfidence = .medium
        case .high:
            proposalConfidence = .high
        }
        let normalizedEdits = try normalizeAnchors(
            draft,
            projectRoot: projectRoot
        )
        let proposal = ModelRepairProposal(
            disposition: .reviewRequired,
            sourceFileIdentity: draft.sourceFile,
            sourceLanguage: draft.sourceLanguage,
            edits: normalizedEdits.map {
                ModelRepairEdit(
                    operation: ModelRepairEditOperation(
                        rawValue: $0.operation.rawValue
                    ) ?? .replace,
                    sourceFileIdentity: draft.sourceFile,
                    originalAnchor: $0.originalAnchor,
                    source: $0.proposedSource
                )
            },
            explanation: draft.explanation,
            confidence: proposalConfidence,
            evidenceUsed: draft.evidence,
            assumptions: draft.assumptions,
            unresolvedRisks: draft.risks
        )
        let context = RepairContext(
            relatedFindingIdentifier: draft.findingIdentifier,
            findingStableKey: draft.findingStableKey,
            findingSeverity: draft.findingSeverity,
            userSelected: true,
            evidenceLevel: draft.evidenceLevelIsDiagnosticBacked
                ? .diagnosticBacked : .sdkRisk,
            diagnostic: draft.diagnostic,
            diagnosticIdentifier: draft.diagnosticIdentifier,
            filePath: draft.sourceFile,
            language: draft.sourceLanguage,
            sourceFragment: draft.sourceFragment,
            enclosingDeclaration: draft.enclosingDeclaration,
            allowedEditingRange: draft.allowedEditingRange,
            sourceFingerprint: draft.sourceFingerprint,
            resolvedSymbolIdentity: draft.resolvedSymbolIdentity,
            candidateSymbolIdentity: draft.candidateSymbolIdentity,
            baselineSDKDeclaration: draft.baselineSDKDeclaration,
            candidateSDKDeclaration: draft.candidateSDKDeclaration,
            sdkDifferences: draft.sdkDifferences,
            compilerFixItEvidence: draft.compilerFixItEvidence,
            deterministicRepairCandidates:
                draft.deterministicRepairCandidates,
            restrictions: [],
            toolchains: draft.toolchains,
            symbols: draft.symbols,
            compilerContext: draft.compilerContext
        )
        let status = FoundationModelProviderStatus(
            availability: .available,
            generation: FoundationModelHostGeneration(
                rawValue: draft.hostModelGeneration
            ),
            reasoningLevel: draft.reasoningLevel,
            supportsTokenCounting: false
        )
        return try FoundationModelProposalValidator.validate(
            proposal,
            context: context,
            status: status,
            projectRoot: projectRoot,
            deferIdentifierResolutionToCandidateBuild: true
        )
    }

    private static func normalizeAnchors(
        _ draft: RepairDraft,
        projectRoot: URL
    ) throws -> [RepairDraftEdit] {
        let root = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        let document = try RepairSourceDocument(
            root: root,
            file: root.appendingPathComponent(draft.sourceFile)
        )
        guard document.fingerprint == draft.sourceFingerprint else {
            throw RepairError.stalePlan(draft.sourceFile)
        }
        let allowedRange = try document.normalizedByteRange(
            draft.allowedEditingRange
        )
        let source = document.data.subdata(in: allowedRange)
        return try draft.edits.map { edit in
            guard !edit.originalAnchor.isEmpty else {
                throw FoundationModelRepairError.invalidProposal(
                    "a draft edit has no source anchor"
                )
            }
            let matches = exactMatches(
                Data(edit.originalAnchor.utf8),
                in: source
            )
            if matches.count == 1 {
                return edit
            }
            if matches.count > 1 {
                throw FoundationModelRepairError.invalidProposal(
                    "a draft source anchor is ambiguous in the permitted source"
                )
            }
            if let anchor = try normalizedWhitespaceAnchor(
                edit.originalAnchor,
                in: source
            ) {
                return replacingAnchor(edit, with: anchor)
            }
            if let anchor = try uniqueTokenAnchor(
                edit.originalAnchor,
                in: source
            ) {
                return replacingAnchor(edit, with: anchor)
            }
            throw FoundationModelRepairError.invalidProposal(
                "a draft source anchor could not be matched by exact text, "
                    + "normalized whitespace, or one unique Swift token sequence"
            )
        }
    }

    private static func replacingAnchor(
        _ edit: RepairDraftEdit,
        with anchor: String
    ) -> RepairDraftEdit {
        RepairDraftEdit(
            operation: edit.operation,
            sourceFileIdentity: edit.sourceFileIdentity,
            originalAnchor: anchor,
            proposedSource: edit.proposedSource
        )
    }

    private static func exactMatches(
        _ needle: Data,
        in source: Data
    ) -> [Range<Int>] {
        guard !needle.isEmpty, needle.count <= source.count else { return [] }
        var result: [Range<Int>] = []
        var lower = 0
        while lower <= source.count - needle.count,
              let range = source.range(
                  of: needle,
                  in: lower..<source.count
              )
        {
            result.append(range)
            lower = range.lowerBound + 1
        }
        return result
    }

    private struct WhitespaceNormalizedBytes {
        let data: Data
        let starts: [Int]
        let ends: [Int]
    }

    private static func normalizedWhitespaceAnchor(
        _ anchor: String,
        in source: Data
    ) throws -> String? {
        let normalizedSource = whitespaceNormalized(source)
        let normalizedAnchor = whitespaceNormalized(Data(anchor.utf8)).data
        guard !normalizedAnchor.isEmpty else { return nil }
        let matches = exactMatches(
            normalizedAnchor,
            in: normalizedSource.data
        )
        guard matches.count <= 1 else {
            throw FoundationModelRepairError.invalidProposal(
                "a normalized-whitespace source anchor is ambiguous"
            )
        }
        guard let match = matches.first,
              match.lowerBound < normalizedSource.starts.count,
              match.upperBound > 0,
              match.upperBound - 1 < normalizedSource.ends.count
        else {
            return nil
        }
        let range = Range(
            uncheckedBounds: (
                lower: normalizedSource.starts[match.lowerBound],
                upper: normalizedSource.ends[match.upperBound - 1]
            )
        )
        return String(data: source.subdata(in: range), encoding: .utf8)
    }

    private static func whitespaceNormalized(
        _ data: Data
    ) -> WhitespaceNormalizedBytes {
        let bytes = Array(data)
        var output: [UInt8] = []
        var starts: [Int] = []
        var ends: [Int] = []
        var index = 0
        while index < bytes.count {
            if isASCIIWhitespace(bytes[index]) {
                let start = index
                while index < bytes.count, isASCIIWhitespace(bytes[index]) {
                    index += 1
                }
                if !output.isEmpty, index < bytes.count {
                    output.append(0x20)
                    starts.append(start)
                    ends.append(index)
                }
                continue
            }
            output.append(bytes[index])
            starts.append(index)
            ends.append(index + 1)
            index += 1
        }
        return WhitespaceNormalizedBytes(
            data: Data(output),
            starts: starts,
            ends: ends
        )
    }

    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private struct TokenSpan {
        let text: String
        let start: Int
        let end: Int
    }

    private static func uniqueTokenAnchor(
        _ anchor: String,
        in source: Data
    ) throws -> String? {
        guard let sourceText = String(data: source, encoding: .utf8) else {
            return nil
        }
        let anchorTokens = Parser.parse(source: anchor)
            .tokens(viewMode: .sourceAccurate)
            .filter { $0.tokenKind != .endOfFile }
            .map(\.text)
        guard !anchorTokens.isEmpty else { return nil }
        let sourceTokens = Parser.parse(source: sourceText)
            .tokens(viewMode: .sourceAccurate)
            .filter { $0.tokenKind != .endOfFile }
            .map {
                TokenSpan(
                    text: $0.text,
                    start:
                        $0.positionAfterSkippingLeadingTrivia.utf8Offset,
                    end: $0.endPositionBeforeTrailingTrivia.utf8Offset
                )
            }
        guard anchorTokens.count <= sourceTokens.count else { return nil }
        var matches: [Range<Int>] = []
        for start in 0...(sourceTokens.count - anchorTokens.count) {
            let slice = sourceTokens[
                start..<(start + anchorTokens.count)
            ]
            if zip(slice, anchorTokens).allSatisfy({
                $0.0.text == $0.1
            }) {
                matches.append(
                    Range(
                        uncheckedBounds: (
                            lower: sourceTokens[start].start,
                            upper:
                                sourceTokens[
                                    start + anchorTokens.count - 1
                                ].end
                        )
                    )
                )
            }
        }
        guard matches.count <= 1 else {
            throw FoundationModelRepairError.invalidProposal(
                "a Swift token-sequence source anchor is ambiguous"
            )
        }
        guard let match = matches.first else { return nil }
        return String(data: source.subdata(in: match), encoding: .utf8)
    }
}
