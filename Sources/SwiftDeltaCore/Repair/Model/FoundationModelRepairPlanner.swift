//===--- FoundationModelRepairPlanner.swift - SwiftDelta ------------------------------------------===//
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

struct FoundationModelRepairPlanner {
    let provider: any FoundationModelRepairProviding
    let progress: OperationProgress
    let now: @Sendable () -> Date

    init(
        provider: any FoundationModelRepairProviding,
        progress: OperationProgress,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.provider = provider
        self.progress = progress
        self.now = now
    }

    func proposeRepairs(
        contexts: [RepairContext],
        options: FoundationModelRepairOptions,
        projectRoot: URL,
        findingsConsidered: Int? = nil,
        initiallySkipped: Int = 0,
        cancellation: @escaping @Sendable () -> Bool
    ) -> (
        repairs: [ProposedRepair],
        failures: [AnalysisFailure],
        summary: FoundationModelPlanningSummary,
        notRepairableReasons: [String: String],
        repairFindingStableKeys: [String: String],
        candidateAttempts: [RepairCandidatePresentation],
        drafts: [RepairDraft]
    ) {
        let considered = findingsConsidered ?? contexts.count + initiallySkipped
        guard !contexts.isEmpty else {
            return (
                [],
                [],
                FoundationModelPlanningSummary(
                    findingsConsidered: considered,
                    processed: 0,
                    skipped: initiallySkipped,
                    deduplicated: 0,
                    deferredByLimit: 0,
                    rejected: 0,
                    convertedIntoRepairs: 0
                ),
                [:],
                [:],
                [],
                []
            )
        }

        let startedAt = now()
        let status = progress.phase(
            "Checking Apple Foundation Models availability",
            completedMessage: "Checked Apple Foundation Models availability"
        ) {
            provider.status(options: options)
        }
        guard status.availability == .available else {
            // Local model capability is optional. Deterministic repair planning
            // remains complete when the host model is not usable.
            return (
                [],
                [],
                FoundationModelPlanningSummary(
                    findingsConsidered: considered,
                    processed: 0,
                    skipped: initiallySkipped,
                    deduplicated: 0,
                    deferredByLimit: 0,
                    rejected: 0,
                    convertedIntoRepairs: 0,
                    unavailable: contexts.count
                ),
                [:],
                [:],
                [],
                []
            )
        }

        let uniqueContexts = deduplicated(contexts)
        let deduplicatedCount = contexts.count - uniqueContexts.count
        let prioritized = uniqueContexts.sorted(by: isHigherPriority)
        let selected = Array(
            prioritized.prefix(options.maximumCandidates)
        )
        let deferredByLimit = prioritized.count - selected.count
        var repairs: [ProposedRepair] = []
        var failures: [AnalysisFailure] = []
        var processed = 0
        var rejected = 0
        var timedOut = 0
        var cancelled = 0
        var notRepairableReasons: [String: String] = [:]
        var repairFindingStableKeys: [String: String] = [:]
        var candidateAttempts: [RepairCandidatePresentation] = []
        var drafts: [RepairDraft] = []
        for (index, context) in selected.enumerated() {
            progress.measure(
                completed: index,
                total: selected.count,
                label: "Repair candidates"
            )
            if cancellation() {
                cancelled = selected.count - index
                failures.append(
                    failure(
                        FoundationModelRepairError.cancelled,
                        context: context
                    )
                )
                break
            }
            guard let boundedOptions = remainingOptions(
                options,
                startedAt: startedAt
            ) else {
                timedOut = selected.count - index
                failures.append(
                    failure(
                        FoundationModelRepairError.timedOut(options.timeout),
                        context: context
                    )
                )
                break
            }
            processed += 1
            var generatedProposal: ModelRepairProposal?
            var generatedStatus: FoundationModelProviderStatus?
            do {
                if status.supportsTokenCounting {
                    let budget = try progress.phase(
                        "Counting Foundation Models repair context tokens",
                        completedMessage:
                            "Counted Foundation Models repair context tokens"
                    ) {
                        progress.measure(
                            completed: index,
                            total: selected.count,
                            label: "Repair candidates"
                        )
                        return try provider.contextBudget(
                            for: context,
                            options: boundedOptions,
                            cancellation: cancellation
                        )
                    }
                    if let budget,
                       budget.tokenCount
                           + FoundationModelContextBudget.totalReserve
                           >= budget.contextSize
                    {
                        throw FoundationModelRepairError.contextSizeExceeded(
                            tokenCount: budget.tokenCount
                                + FoundationModelContextBudget.totalReserve,
                            contextSize: budget.contextSize
                        )
                    }
                }
                let response = try progress.phase(
                    "Generating Foundation Models repair proposal",
                    completedMessage: "Generated Foundation Models repair proposal"
                ) {
                    progress.measure(
                        completed: index,
                        total: selected.count,
                        label: "Repair candidates"
                    )
                    return try proposeWithBoundedRetry(
                        context: context,
                        options: options,
                        startedAt: startedAt,
                        cancellation: cancellation
                    )
                }
                if let initial = response.initialWithoutEdit {
                    candidateAttempts.append(
                        candidatePresentation(
                            initial,
                            context: context,
                            status: .noProposal,
                            reason:
                                "The initial structured response contained no "
                                + "source edit. SwiftDelta requested one focused "
                                + "corrective generation.",
                            validationStage:
                                RepairDraftIssueStage.incompleteDraft.rawValue
                        )
                    )
                }
                var effectiveProposal = response.proposal
                var effectiveStatus = response.status
                generatedProposal = effectiveProposal
                generatedStatus = effectiveStatus
                var initialDraft = try FoundationModelRepairDraftBuilder.build(
                    proposal: effectiveProposal,
                    context: context,
                    status: effectiveStatus
                )
                guard effectiveProposal.disposition != .notRepairable else {
                    rejected += 1
                    let reason = conciseOutcomeReason(
                        effectiveProposal.explanation
                    )
                    notRepairableReasons[context.findingStableKey] = reason
                    if let initialDraft {
                        drafts.append(initialDraft)
                        candidateAttempts.append(
                            candidatePresentation(
                                initialDraft,
                                status: .needsValidation,
                                reason: reason
                            )
                        )
                    } else {
                        candidateAttempts.append(
                            candidatePresentation(
                                effectiveProposal,
                                context: context,
                                status: .noProposal,
                                reason: reason
                            )
                        )
                    }
                    continue
                }
                let validatedRepairs: [ProposedRepair]
                do {
                    validatedRepairs = try validateProposal(
                        effectiveProposal,
                        status: effectiveStatus,
                        context: context,
                        projectRoot: projectRoot,
                        index: index,
                        total: selected.count
                    )
                } catch {
                    guard shouldCorrectValidationFailure(error),
                          !cancellation(),
                          let correctedOptions = remainingOptions(
                            options,
                            startedAt: startedAt
                          )
                    else { throw error }
                    if let rejectedDraft = try FoundationModelRepairDraftBuilder.build(
                        proposal: effectiveProposal,
                        context: context,
                        status: effectiveStatus,
                        validationError: error
                    ) {
                        drafts.append(rejectedDraft)
                        candidateAttempts.append(
                            candidatePresentation(
                                rejectedDraft,
                                status: .needsValidation,
                                reason: error.localizedDescription
                            )
                        )
                    }
                    progress.message(
                        "Retrying Foundation Models with the exact source-anchor "
                            + "or syntax validation failure"
                    )
                    let correctiveContext = context.addingRestriction(
                        correctiveValidationRestriction(error)
                    )
                    let corrected = try provider.propose(
                        for: correctiveContext,
                        options: correctedOptions,
                        cancellation: cancellation
                    )
                    effectiveProposal = corrected.0
                    effectiveStatus = corrected.1
                    generatedProposal = effectiveProposal
                    generatedStatus = effectiveStatus
                    initialDraft = try FoundationModelRepairDraftBuilder.build(
                        proposal: effectiveProposal,
                        context: context,
                        status: effectiveStatus
                    )
                    validatedRepairs = try validateProposal(
                        effectiveProposal,
                        status: effectiveStatus,
                        context: correctiveContext,
                        projectRoot: projectRoot,
                        index: index,
                        total: selected.count
                    )
                }
                if !validatedRepairs.isEmpty {
                    repairs.append(contentsOf: validatedRepairs)
                    if let initialDraft {
                        drafts.append(initialDraft)
                    }
                    for repair in validatedRepairs {
                        repairFindingStableKeys[repair.repairIdentifier] =
                            context.findingStableKey
                    }
                } else {
                    rejected += 1
                    let reason =
                        "The structured proposal did not contain an "
                        + "applicable source edit."
                    if let initialDraft {
                        let draft = initialDraft.replacingEdits(
                            initialDraft.edits,
                            issues: initialDraft.initialIssues + [
                                RepairDraftIssue(
                                    stage: .incompleteDraft,
                                    message: reason
                                ),
                            ]
                        )
                        drafts.append(draft)
                        candidateAttempts.append(
                            candidatePresentation(
                                draft,
                                status: .needsValidation,
                                reason: reason
                            )
                        )
                    }
                }
            } catch FoundationModelRepairError.cancelled {
                cancelled = selected.count - index
                failures.append(
                    failure(
                        FoundationModelRepairError.cancelled,
                        context: context
                    )
                )
                break
            } catch FoundationModelRepairError.timedOut(_) {
                timedOut = selected.count - index
                failures.append(
                    failure(
                        FoundationModelRepairError.timedOut(options.timeout),
                        context: context
                    )
                )
                break
            } catch {
                rejected += 1
                var retainedDraft = false
                if let generatedProposal, let generatedStatus {
                    do {
                        if let draft =
                            try FoundationModelRepairDraftBuilder.build(
                                proposal: generatedProposal,
                                context: context,
                                status: generatedStatus,
                                validationError: error
                            )
                        {
                            retainedDraft = true
                            drafts.append(draft)
                            candidateAttempts.append(
                                candidatePresentation(
                                    draft,
                                    status: draft.initialIssues.contains {
                                        $0.stage == .hardSafetyRejection
                                    } ? .rejected : .needsValidation,
                                    reason: error.localizedDescription
                                )
                            )
                        } else {
                            candidateAttempts.append(
                                candidatePresentation(
                                    generatedProposal,
                                    context: context,
                                    status: generatedProposal.edits.isEmpty
                                        ? .noProposal : .rejected,
                                    reason: error.localizedDescription,
                                    validationStage: generatedProposal.edits.isEmpty
                                        ? RepairDraftIssueStage.incompleteDraft.rawValue
                                        : RepairDraftIssueStage.evidenceMismatch.rawValue
                                )
                            )
                        }
                    } catch {
                        candidateAttempts.append(
                            candidatePresentation(
                                generatedProposal,
                                context: context,
                                status: .rejected,
                                reason: error.localizedDescription,
                                validationStage:
                                    RepairDraftIssueStage.hardSafetyRejection.rawValue
                            )
                        )
                    }
                }
                if !retainedDraft {
                    failures.append(failure(error, context: context))
                }
            }
            progress.measure(
                completed: index + 1,
                total: selected.count,
                label: "Repair candidates"
            )
        }
        let plan = RepairPlanBuilder.build(
            projectRoot: projectRoot,
            repairs: repairs
        )
        let conflictIDs = Set(plan.conflicts.flatMap(\.repairIdentifiers))
        let accepted = repairs.filter {
            !conflictIDs.contains($0.repairIdentifier)
        }
        rejected += repairs.count - accepted.count
        if !plan.conflicts.isEmpty {
            failures.append(
                AnalysisFailure(
                    kind: .parse,
                    message:
                        "Apple Foundation Models proposed overlapping or "
                        + "contradictory edits; no conflicting proposal was accepted.",
                    location: nil
                )
            )
        }
        let acceptedIdentifiers = Set(accepted.map(\.repairIdentifier))
        let uniqueDrafts = uniqueByIdentifier(
            drafts,
            identifier: \.draftIdentifier
        )
        let uniqueCandidateAttempts = uniqueByIdentifier(
            candidateAttempts,
            identifier: \.candidateIdentifier
        )
        return (
            accepted,
            failures,
            FoundationModelPlanningSummary(
                findingsConsidered: considered,
                processed: processed,
                skipped: initiallySkipped,
                deduplicated: deduplicatedCount,
                deferredByLimit: deferredByLimit,
                rejected: rejected,
                drafted: uniqueDrafts.count,
                convertedIntoRepairs: accepted.count,
                timedOut: timedOut,
                cancelled: cancelled
            ),
            notRepairableReasons,
            repairFindingStableKeys.filter {
                acceptedIdentifiers.contains($0.key)
            },
            uniqueCandidateAttempts,
            uniqueDrafts
        )
    }

    private func uniqueByIdentifier<Value>(
        _ values: [Value],
        identifier: KeyPath<Value, String>
    ) -> [Value] {
        var seen = Set<String>()
        return values.filter {
            seen.insert($0[keyPath: identifier]).inserted
        }
    }

    private func candidatePresentation(
        _ draft: RepairDraft,
        status: RepairCandidateStatus,
        reason: String
    ) -> RepairCandidatePresentation {
        RepairCandidatePresentation(
            candidateIdentifier: RepairFingerprint.identifier([
                "draft-candidate",
                draft.draftIdentifier,
            ]),
            draftIdentifier: draft.draftIdentifier,
            findingStableKey: draft.findingStableKey,
            findingIdentifier: draft.findingIdentifier,
            title: draft.findingTitle,
            location: draft.location,
            symbol: draft.symbol,
            status: status,
            repairSource: draft.modelIdentity,
            confidence: draft.confidence,
            summary: draft.edits.count == 1
                ? "\(draft.edits[0].operation.rawValue) draft"
                : "\(draft.edits.count) coordinated edit draft",
            explanation: draft.explanation,
            evidence: draft.evidence,
            risks: draft.assumptions
                + draft.risks
                + draft.initialIssues.map {
                    "\($0.stage.rawValue): \($0.message)"
                },
            edits: draft.edits.map {
                RepairCandidateEditPresentation(
                    operation: $0.operation.rawValue,
                    filePath: $0.sourceFileIdentity,
                    originalText: $0.originalAnchor,
                    replacementText: $0.proposedSource
                )
            },
            verificationMessage: reason
        )
    }

    private func candidatePresentation(
        _ proposal: ModelRepairProposal,
        context: RepairContext,
        status: RepairCandidateStatus,
        reason: String,
        validationStage: String? = nil
    ) -> RepairCandidatePresentation {
        let confidence: Confidence = switch proposal.confidence {
        case .low: .low
        case .medium: .medium
        case .high: .high
        }
        return RepairCandidatePresentation(
            candidateIdentifier: RepairFingerprint.identifier([
                "model-attempt",
                context.findingStableKey,
                proposal.disposition.rawValue,
                proposal.explanation,
                reason,
            ] + proposal.edits.flatMap {
                [
                    $0.operation.rawValue,
                    $0.sourceFileIdentity,
                    $0.originalAnchor,
                    $0.source,
                ]
            }),
            findingStableKey: context.findingStableKey,
            findingIdentifier: context.relatedFindingIdentifier,
            title: context.diagnostic?.message
                ?? context.sdkDifferences.first
                ?? "SDK compatibility risk",
            location: context.diagnostic?.location
                ?? SourceLocation(
                    path: context.filePath,
                    line: context.allowedEditingRange.start.line,
                    column: context.allowedEditingRange.start.column
                ),
            symbol: context.symbols.baselinePreciseIdentifier
                ?? context.resolvedSymbolIdentity,
            status: status,
            repairSource: "Apple Foundation Models",
            confidence: confidence,
            summary: proposal.edits.isEmpty
                ? "No source proposal"
                : (
                    proposal.edits.count == 1
                        ? "\(proposal.edits[0].operation.rawValue) proposal"
                        : "\(proposal.edits.count) coordinated edit proposal"
                ),
            explanation: proposal.explanation,
            evidence: proposal.evidenceUsed,
            risks: proposal.assumptions + proposal.unresolvedRisks + [reason],
            edits: proposal.edits.map {
                RepairCandidateEditPresentation(
                    operation: $0.operation.rawValue,
                    filePath: $0.sourceFileIdentity,
                    originalText: $0.originalAnchor,
                    replacementText: $0.source
                )
            },
            verificationMessage: reason,
            suppliedSource: context.sourceFragment,
            baselineDeclaration: context.baselineSDKDeclaration,
            candidateDeclaration: context.candidateSDKDeclaration,
            modelDisposition: proposal.disposition.rawValue,
            validationStage: validationStage
        )
    }

    private func conciseOutcomeReason(_ value: String) -> String {
        let normalized = value
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty
            ? "The local model found no evidence-backed source edit."
            : String(normalized.prefix(500))
    }

    private func proposeWithBoundedRetry(
        context: RepairContext,
        options: FoundationModelRepairOptions,
        startedAt: Date,
        cancellation: @escaping @Sendable () -> Bool
    ) throws -> (
        proposal: ModelRepairProposal,
        status: FoundationModelProviderStatus,
        initialWithoutEdit: ModelRepairProposal?
    ) {
        let initial = try proposeRecoveringGenerationFailure(
            context: context,
            options: options,
            startedAt: startedAt,
            cancellation: cancellation
        )
        guard initial.0.edits.isEmpty,
              initial.0.disposition != .notRepairable,
              !cancellation()
        else {
            return (initial.0, initial.1, nil)
        }
        progress.message(
            "Retrying Foundation Models with the missing source-edit "
                + "requirement for this finding"
        )
        guard let boundedOptions = remainingOptions(
            options,
            startedAt: startedAt
        ) else {
            return (initial.0, initial.1, nil)
        }
        let correctiveContext = context.addingRestriction(
            "The previous structured response contained no source edit. "
                + "Return at least one exact anchored operation when the "
                + "supplied evidence supports a concrete migration. If it "
                + "does not, return notRepairable and identify the exact "
                + "missing evidence rather than general migration advice."
        )
        do {
            let corrected = try provider.propose(
                for: correctiveContext,
                options: boundedOptions,
                cancellation: cancellation
            )
            return (corrected.0, corrected.1, initial.0)
        } catch {
            return (initial.0, initial.1, nil)
        }
    }

    private func validateProposal(
        _ proposal: ModelRepairProposal,
        status: FoundationModelProviderStatus,
        context: RepairContext,
        projectRoot: URL,
        index: Int,
        total: Int
    ) throws -> [ProposedRepair] {
        try progress.phase(
            "Validating Foundation Models repair proposal",
            completedMessage: "Validated Foundation Models repair proposal"
        ) {
            progress.measure(
                completed: index,
                total: total,
                label: "Repair candidates"
            )
            return try FoundationModelProposalValidator.validate(
                proposal,
                context: context,
                status: status,
                projectRoot: projectRoot
            )
        }
    }

    private func shouldCorrectValidationFailure(_ error: any Error) -> Bool {
        guard let modelError = error as? FoundationModelRepairError,
              case let .invalidProposal(reason) = modelError
        else { return false }
        let recoverableMarkers = [
            "source anchor", "edited Swift source", "does not parse",
            "replacement introduces identifiers", "replacement is empty",
            "unchanged", "source edits",
        ]
        return recoverableMarkers.contains { reason.contains($0) }
    }

    private func correctiveValidationRestriction(_ error: any Error) -> String {
        let detail = conciseOutcomeReason(error.localizedDescription)
        return "The previous typed edit failed local structural validation: "
            + "\(detail) Copy every originalAnchor exactly from the allowed "
            + "source fragment, modify the actual source use rather than an "
            + "SDK declaration, and return complete Swift syntax. Return "
            + "notRepairable if that cannot be done from supplied evidence."
    }

    private func proposeRecoveringGenerationFailure(
        context: RepairContext,
        options: FoundationModelRepairOptions,
        startedAt: Date,
        cancellation: @escaping @Sendable () -> Bool
    ) throws -> (ModelRepairProposal, FoundationModelProviderStatus) {
        let maximumAttempts = 3
        var attempt = 0
        while true {
            attempt += 1
            do {
                guard let boundedOptions = remainingOptions(
                    options,
                    startedAt: startedAt
                ) else {
                    throw FoundationModelRepairError.timedOut(options.timeout)
                }
                return try provider.propose(
                    for: context,
                    options: boundedOptions,
                    cancellation: cancellation
                )
            } catch let error as FoundationModelRepairError {
                guard attempt < maximumAttempts,
                      error.isRecoverableGenerationFailure,
                      !cancellation()
                else {
                    throw error
                }
                progress.message(
                    "Retrying recoverable Foundation Models generation failure "
                        + "(\(attempt) of 2 retries)"
                )
            }
        }
    }

    private func remainingOptions(
        _ options: FoundationModelRepairOptions,
        startedAt: Date
    ) -> FoundationModelRepairOptions? {
        let elapsed = now().timeIntervalSince(startedAt)
        let remaining = options.timeout - elapsed
        guard remaining > 0 else {
            return nil
        }
        return FoundationModelRepairOptions(
            reasoningLevel: options.reasoningLevel,
            timeout: remaining,
            maximumCandidates: options.maximumCandidates
        )
    }

    private func deduplicated(
        _ contexts: [RepairContext]
    ) -> [RepairContext] {
        var values: [FoundationModelContextIdentity: RepairContext] = [:]
        for context in contexts {
            let identity = FoundationModelContextIdentity(context)
            guard let current = values[identity] else {
                values[identity] = context
                continue
            }
            if isHigherPriority(context, than: current) {
                values[identity] = context
            }
        }
        return Array(values.values)
    }

    private func isHigherPriority(
        _ left: RepairContext,
        than right: RepairContext
    ) -> Bool {
        if left.userSelected != right.userSelected {
            return left.userSelected
        }
        let leftDiagnosticRank = left.diagnostic?.severity.rank ?? 0
        let rightDiagnosticRank = right.diagnostic?.severity.rank ?? 0
        if leftDiagnosticRank != rightDiagnosticRank {
            return leftDiagnosticRank > rightDiagnosticRank
        }
        if left.findingSeverity.rank != right.findingSeverity.rank {
            return left.findingSeverity.rank > right.findingSeverity.rank
        }
        if left.evidenceLevel != right.evidenceLevel {
            return left.evidenceLevel.rawValue > right.evidenceLevel.rawValue
        }
        return (
            left.filePath,
            left.allowedEditingRange.start.utf8Offset,
            left.relatedFindingIdentifier
        ) < (
            right.filePath,
            right.allowedEditingRange.start.utf8Offset,
            right.relatedFindingIdentifier
        )
    }

    private func failure(
        _ error: any Error,
        context: RepairContext
    ) -> AnalysisFailure {
        AnalysisFailure(
            kind: .parse,
            message: error.localizedDescription,
            location: context.diagnostic?.location
                ?? SourceLocation(path: context.filePath)
        )
    }
}

private struct FoundationModelContextIdentity: Hashable {
    let filePath: String
    let sourceStart: Int
    let sourceEnd: Int
    let sourceFingerprint: String
    let baselineSymbol: String
    let candidateSymbol: String
    let target: String?
    let module: String?
    let sdk: String

    init(_ context: RepairContext) {
        filePath = context.filePath
        sourceStart = context.allowedEditingRange.start.utf8Offset
        sourceEnd = context.allowedEditingRange.end.utf8Offset
        sourceFingerprint = context.sourceFingerprint.digest
        baselineSymbol = context.resolvedSymbolIdentity
        candidateSymbol = context.candidateSymbolIdentity
        target = context.compilerContext.target
        module = context.compilerContext.moduleName
        sdk = context.compilerContext.sdkIdentifier
    }
}

enum FoundationModelProposalValidator {
    static func validate(
        _ proposal: ModelRepairProposal,
        context: RepairContext,
        status: FoundationModelProviderStatus,
        projectRoot: URL,
        deferIdentifierResolutionToCandidateBuild: Bool = false
    ) throws -> [ProposedRepair] {
        guard proposal.disposition != .notRepairable else {
            return []
        }
        guard proposal.sourceFileIdentity == context.filePath else {
            throw FoundationModelRepairError.invalidProposal(
                "the returned source file identity does not match the repair context"
            )
        }
        guard proposal.sourceLanguage == context.language else {
            throw FoundationModelRepairError.invalidProposal(
                "the returned source language does not match the repair context"
            )
        }
        guard !proposal.edits.isEmpty, proposal.edits.count <= 8 else {
            throw FoundationModelRepairError.invalidProposal(
                "the proposal must contain between one and eight source edits"
            )
        }
        let root = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        let document = try RepairSourceDocument(
            root: root,
            file: root.appendingPathComponent(context.filePath)
        )
        guard document.fingerprint == context.sourceFingerprint else {
            throw RepairError.stalePlan(context.filePath)
        }
        let allowedRange = try document.normalizedByteRange(
            context.allowedEditingRange
        )
        let allowedData = document.data.subdata(in: allowedRange)
        guard String(data: allowedData, encoding: .utf8)
            == context.sourceFragment
        else {
            throw RepairError.stalePlan(context.filePath)
        }
        let resolved = try proposal.edits.map {
            try resolve(
                $0,
                context: context,
                document: document,
                allowedRange: allowedRange
            )
        }
        try validateConflicts(resolved)
        try validateIntroducedImports(
            edits: resolved,
            context: context
        )
        if !deferIdentifierResolutionToCandidateBuild {
            try validateIntroducedIdentifiers(
                edits: resolved,
                context: context
            )
        }
        var modified = document.data
        for edit in resolved.sorted(by: {
            if $0.range.lowerBound != $1.range.lowerBound {
                return $0.range.lowerBound > $1.range.lowerBound
            }
            return $0.range.upperBound > $1.range.upperBound
        }) {
            modified.replaceSubrange(
                edit.range,
                with: Data(edit.replacement.utf8)
            )
        }
        try validateModifiedSource(modified, language: context.language)
        let provider = "on-device"
        let execution = "On-device"
        let generation = status.generation?.rawValue ?? "unsupported"
        let riskSummary = proposal.unresolvedRisks.isEmpty
            ? ""
            : " Unresolved risks: "
                + proposal.unresolvedRisks.map(concise).joined(separator: "; ")
        let assumptionSummary = proposal.assumptions.isEmpty
            ? ""
            : " Assumptions: "
                + proposal.assumptions.map(concise).joined(separator: "; ")
        let evidenceSummary = context.evidenceLevel == .diagnosticBacked
            ? "The proposal is backed by a uniquely matched candidate compiler diagnostic."
            : "No unique candidate compiler diagnostic matched this exact SDK-resolved source use; the edit remains review-required and can commit only if candidate-Xcode verification proves that the targeted SDK finding disappeared."
        return resolved.enumerated().map { index, edit in
            let repairIdentifier = RepairFingerprint.identifier([
                RepairEvidenceSource.foundationModels.rawValue,
                context.relatedFindingIdentifier,
                context.filePath,
                String(edit.range.lowerBound),
                String(edit.range.upperBound),
                edit.original,
                edit.replacement,
                context.sourceFingerprint.digest,
                context.candidateSymbolIdentity,
                provider,
                generation,
                status.reasoningLevel,
                String(index),
            ])
            return ProposedRepair(
                repairIdentifier: repairIdentifier,
                relatedFindingIdentifier: context.relatedFindingIdentifier,
                evidenceSource: .foundationModels,
                language: context.language,
                filePath: context.filePath,
                sourceRange: RepairSourceRange(
                    start: sourcePosition(
                        edit.range.lowerBound,
                        in: document.data
                    ),
                    end: sourcePosition(
                        edit.range.upperBound,
                        in: document.data
                    )
                ),
                originalText: edit.original,
                replacementText: edit.replacement,
                fileFingerprint: context.sourceFingerprint,
                confidence: .low,
                safety: proposal.disposition == .repairable
                    ? .reviewRequired : .suggestionOnly,
                explanation:
                    concise(proposal.conciseRationale)
                    + " Coordinated edit \(index + 1) of \(resolved.count)."
                    + " Model-reported evidence confidence: "
                    + proposal.confidence.rawValue
                    + "; this is not proof of repair safety. "
                    + evidenceSummary
                    + assumptionSummary
                    + riskSummary,
                verificationRequirement: .candidateBuild,
                toolchains: context.toolchains,
                symbols: context.symbols,
                compilerContext: context.compilerContext,
                generatedBy: "Apple Foundation Models",
                provider: provider,
                execution: execution,
                hostModelGeneration: generation,
                reasoningLevel: status.reasoningLevel,
                modelGenerated: true,
                requiresReview: true
            )
        }
    }

    private struct ResolvedEdit {
        let operation: ModelRepairEditOperation
        let range: Range<Int>
        let original: String
        let replacement: String
    }

    private static func resolve(
        _ edit: ModelRepairEdit,
        context: RepairContext,
        document: RepairSourceDocument,
        allowedRange: Range<Int>
    ) throws -> ResolvedEdit {
        guard edit.sourceFileIdentity == context.filePath else {
            throw FoundationModelRepairError.invalidProposal(
                "an edit names a file outside its repair context"
            )
        }
        guard !edit.originalAnchor.isEmpty else {
            throw FoundationModelRepairError.invalidProposal(
                "an edit has an empty source anchor"
            )
        }
        switch edit.operation {
        case .delete:
            guard edit.source.isEmpty else {
                throw FoundationModelRepairError.invalidProposal(
                    "a delete operation must not contain replacement source"
                )
            }
        case .replace:
            guard !edit.source.isEmpty,
                  edit.source != edit.originalAnchor
            else {
                throw FoundationModelRepairError.invalidProposal(
                    "a replacement is empty or leaves the source unchanged"
                )
            }
        case .insertBefore, .insertAfter:
            guard !edit.source.isEmpty else {
                throw FoundationModelRepairError.invalidProposal(
                    "an insertion does not contain source"
                )
            }
        }
        let anchor = Data(edit.originalAnchor.utf8)
        let matches = occurrences(
            of: anchor,
            in: document.data,
            searchRange: allowedRange
        )
        guard matches.count == 1, let match = matches.first else {
            throw FoundationModelRepairError.invalidProposal(
                matches.isEmpty
                    ? "a source anchor does not match the permitted source"
                    : "a source anchor is ambiguous in the permitted source"
            )
        }
        let range: Range<Int>
        let original: String
        let replacement: String
        switch edit.operation {
        case .replace:
            range = match
            original = edit.originalAnchor
            replacement = edit.source
        case .delete:
            range = match
            original = edit.originalAnchor
            replacement = ""
        case .insertBefore:
            range = match.lowerBound..<match.lowerBound
            original = ""
            replacement = edit.source
        case .insertAfter:
            range = match.upperBound..<match.upperBound
            original = ""
            replacement = edit.source
        }
        return ResolvedEdit(
            operation: edit.operation,
            range: range,
            original: original,
            replacement: replacement
        )
    }

    private static func occurrences(
        of needle: Data,
        in haystack: Data,
        searchRange: Range<Int>
    ) -> [Range<Int>] {
        guard !needle.isEmpty,
              searchRange.lowerBound >= 0,
              searchRange.upperBound <= haystack.count,
              needle.count <= searchRange.count
        else {
            return []
        }
        var values: [Range<Int>] = []
        var lower = searchRange.lowerBound
        while lower <= searchRange.upperBound - needle.count,
              let match = haystack.range(
                of: needle,
                in: lower..<searchRange.upperBound
              )
        {
            values.append(match)
            lower = match.lowerBound + 1
        }
        return values
    }

    private static func validateConflicts(
        _ edits: [ResolvedEdit]
    ) throws {
        for leftIndex in edits.indices {
            for rightIndex in edits.indices where rightIndex > leftIndex {
                let left = edits[leftIndex].range
                let right = edits[rightIndex].range
                let bothInsertions = left.isEmpty && right.isEmpty
                let sameInsertion = bothInsertions
                    && left.lowerBound == right.lowerBound
                let insertionInsideRange =
                    left.isEmpty
                    && right.lowerBound <= left.lowerBound
                    && left.lowerBound <= right.upperBound
                    || right.isEmpty
                    && left.lowerBound <= right.lowerBound
                    && right.lowerBound <= left.upperBound
                if sameInsertion
                    || insertionInsideRange
                    || (!left.isEmpty && !right.isEmpty && left.overlaps(right))
                {
                    throw FoundationModelRepairError.invalidProposal(
                        "the proposal contains overlapping or contradictory edits"
                    )
                }
            }
        }
    }

    private static func validateIntroducedImports(
        edits: [ResolvedEdit],
        context: RepairContext
    ) throws {
        let evidence = (
            [context.candidateSDKDeclaration]
            + context.sdkDifferences
            + context.compilerFixItEvidence
            + context.deterministicRepairCandidates
        ).joined(separator: "\n")
        let pattern = #"(?m)^\s*(?:@testable\s+)?import\s+([A-Za-z_][A-Za-z0-9_]*)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return
        }
        for edit in edits {
            let range = NSRange(edit.replacement.startIndex..., in: edit.replacement)
            for match in expression.matches(in: edit.replacement, range: range) {
                guard match.numberOfRanges > 1,
                      let moduleRange = Range(match.range(at: 1), in: edit.replacement)
                else {
                    continue
                }
                let module = String(edit.replacement[moduleRange])
                guard evidence.range(
                    of: #"\b\#(NSRegularExpression.escapedPattern(for: module))\b"#,
                    options: .regularExpression
                ) != nil
                else {
                    throw FoundationModelRepairError.invalidProposal(
                        "an introduced import is not supported by compiler or SDK evidence"
                    )
                }
            }
        }
    }

    private static func validateIntroducedIdentifiers(
        edits: [ResolvedEdit],
        context: RepairContext
    ) throws {
        let evidence = (
            [
                context.sourceFragment,
                context.enclosingDeclaration,
                context.baselineSDKDeclaration,
                context.candidateSDKDeclaration,
                context.resolvedSymbolIdentity,
                context.candidateSymbolIdentity,
            ]
            + context.sdkDifferences
            + context.compilerFixItEvidence
            + context.deterministicRepairCandidates
        ).joined(separator: "\n")
        var allowed = identifiers(in: evidence)
            .union(languageKeywords)
            .union([
                "iOS", "macOS", "tvOS", "watchOS", "visionOS",
                "swift", "objc", "c", "cpp",
            ])
        for edit in edits {
            allowed.formUnion(declaredIdentifiers(in: edit.replacement))
        }
        let introduced = edits.reduce(into: Set<String>()) { result, edit in
            result.formUnion(
                identifiers(
                    inReplacement: edit.replacement,
                    language: context.language
                )
            )
        }.subtracting(allowed)
        guard introduced.isEmpty else {
            throw FoundationModelRepairError.invalidProposal(
                "replacement introduces identifiers absent from the supplied source, compiler, and candidate SDK evidence: "
                    + introduced.sorted().joined(separator: ", ")
            )
        }
    }

    private static func identifiers(in source: String) -> Set<String> {
        guard let expression = try? NSRegularExpression(
            pattern: #"[A-Za-z_][A-Za-z0-9_]*"#
        ) else {
            return []
        }
        let range = NSRange(source.startIndex..., in: source)
        return Set(expression.matches(in: source, range: range).compactMap {
            Range($0.range, in: source).map { String(source[$0]) }
        })
    }

    private static func identifiers(
        inReplacement source: String,
        language: RepairLanguage
    ) -> Set<String> {
        if language == .swift {
            return Set(
                Parser.parse(source: source).tokens(viewMode: .sourceAccurate)
                    .compactMap { token in
                        switch token.tokenKind {
                        case .identifier(let value),
                             .dollarIdentifier(let value):
                            value
                        default:
                            nil
                        }
                    }
            )
        }
        return identifiers(in: nativeCodeWithoutCommentsAndLiterals(source))
    }

    private static func declaredIdentifiers(in source: String) -> Set<String> {
        let pattern =
            #"\b(?:let|var|func|class|struct|enum|protocol|typealias|actor)\s+([A-Za-z_][A-Za-z0-9_]*)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let range = NSRange(source.startIndex..., in: source)
        return Set(expression.matches(in: source, range: range).compactMap {
            guard $0.numberOfRanges > 1,
                  let match = Range($0.range(at: 1), in: source)
            else {
                return nil
            }
            return String(source[match])
        })
    }

    private static let languageKeywords: Set<String> = [
        "actor", "any", "as", "associatedtype", "async", "await", "break",
        "available", "case", "catch", "class", "continue", "default",
        "defer", "deinit",
        "delete", "do", "else", "enum", "extension", "false", "fileprivate",
        "final", "for", "func", "guard", "if", "import", "in", "init",
        "inout", "internal", "is", "isolated", "let", "MainActor", "nil",
        "nonisolated", "preconcurrency",
        "open", "operator", "private", "protocol", "public", "repeat",
        "return", "self", "Self", "Sendable", "sending", "some", "static",
        "struct", "subscript",
        "super", "switch", "throw", "throws", "true", "try", "typealias",
        "var", "weak", "where", "while",
    ]

    private static func validateModifiedSource(
        _ data: Data,
        language: RepairLanguage
    ) throws {
        guard let source = String(data: data, encoding: .utf8) else {
            throw FoundationModelRepairError.invalidProposal(
                "the edited source is not valid UTF-8"
            )
        }
        if language == .swift {
            guard !Parser.parse(source: source).hasError else {
                throw FoundationModelRepairError.invalidProposal(
                    "the complete edited Swift source does not parse"
                )
            }
            return
        }
        guard balancedDelimiters(in: source) else {
            throw FoundationModelRepairError.invalidProposal(
                "the complete edited native source has unbalanced delimiters"
            )
        }
    }

    private static func balancedDelimiters(in source: String) -> Bool {
        var stack: [Character] = []
        let opening: Set<Character> = ["(", "[", "{"]
        let pairs: [Character: Character] = [")": "(", "]": "[", "}": "{"]
        enum State {
            case code
            case lineComment
            case blockComment
            case quoted(Character)
        }
        var state = State.code
        var escaped = false
        let characters = Array(source)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            let next = index + 1 < characters.count
                ? characters[index + 1] : nil
            switch state {
            case .lineComment:
                if character == "\n" {
                    state = .code
                }
                index += 1
                continue
            case .blockComment:
                if character == "*", next == "/" {
                    state = .code
                    index += 2
                } else {
                    index += 1
                }
                continue
            case .quoted(let delimiter):
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == delimiter {
                    state = .code
                }
                index += 1
                continue
            case .code:
                break
            }
            if character == "/", next == "/" {
                state = .lineComment
                index += 2
                continue
            }
            if character == "/", next == "*" {
                state = .blockComment
                index += 2
                continue
            }
            if character == "\"" || character == "'" {
                state = .quoted(character)
                index += 1
                continue
            }
            if opening.contains(character) {
                stack.append(character)
            } else if let expected = pairs[character] {
                guard stack.popLast() == expected else {
                    return false
                }
            }
            index += 1
        }
        switch state {
        case .code, .lineComment:
            return stack.isEmpty
        case .blockComment, .quoted:
            return false
        }
    }

    private static func nativeCodeWithoutCommentsAndLiterals(
        _ source: String
    ) -> String {
        enum State {
            case code
            case lineComment
            case blockComment
            case quoted(Character)
        }
        var state = State.code
        var escaped = false
        let characters = Array(source)
        var result = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            let next = index + 1 < characters.count
                ? characters[index + 1] : nil
            switch state {
            case .lineComment:
                if character == "\n" {
                    state = .code
                    result.append(character)
                } else {
                    result.append(" ")
                }
                index += 1
            case .blockComment:
                if character == "*", next == "/" {
                    state = .code
                    result.append(contentsOf: "  ")
                    index += 2
                } else {
                    result.append(character == "\n" ? "\n" : " ")
                    index += 1
                }
            case .quoted(let delimiter):
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == delimiter {
                    state = .code
                }
                result.append(character == "\n" ? "\n" : " ")
                index += 1
            case .code:
                if character == "/", next == "/" {
                    state = .lineComment
                    result.append(contentsOf: "  ")
                    index += 2
                } else if character == "/", next == "*" {
                    state = .blockComment
                    result.append(contentsOf: "  ")
                    index += 2
                } else if character == "\"" || character == "'" {
                    state = .quoted(character)
                    result.append(" ")
                    index += 1
                } else {
                    result.append(character)
                    index += 1
                }
            }
        }
        return result
    }

    private static func sourcePosition(
        _ offset: Int,
        in data: Data
    ) -> RepairSourcePosition {
        let prefix = data.prefix(offset)
        let line = prefix.count(where: { $0 == 0x0A }) + 1
        let lineStart = prefix.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
        let column = String(
            decoding: prefix.dropFirst(lineStart),
            as: UTF8.self
        ).count + 1
        return RepairSourcePosition(
            line: line,
            column: column,
            utf8Offset: offset
        )
    }

    private static func concise(_ rationale: String) -> String {
        let normalized = rationale
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(normalized.prefix(500))
    }
}
