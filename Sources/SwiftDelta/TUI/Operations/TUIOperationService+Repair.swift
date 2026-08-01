//===--- TUIOperationService+Repair.swift - SwiftDelta ------------------------------------------===//
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

extension CoreTUIOperationService {
    func automaticallyValidateRepairCandidates(
        _ output: RepairPlanningOutput,
        root: URL,
        workflow: TUIWorkflowSettings,
        runner: any ProcessRunning,
        progress: OperationProgress,
        cancellation: @escaping @Sendable () -> Bool,
        pauseRequested: @escaping @Sendable () -> Bool = { false },
        validation:
            ((RepairCandidatePresentation, RepairDraft?) throws
                -> [ProposedRepair])? = nil
    ) -> TUIPreparedRepairPlan {
        let conflictIdentifiers = Set(
            output.plan.conflicts.flatMap(\.repairIdentifiers)
        )
        let drafts = Dictionary(
            output.repairDrafts.map { ($0.draftIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let candidates = output.repairCandidates.filter { candidate in
            guard !candidate.edits.isEmpty,
                  !candidate.repairIdentifiers.contains(
                    where: conflictIdentifiers.contains
                  ),
                  candidate.draftIdentifier.flatMap({ drafts[$0] })?
                    .initialIssues.contains(where: {
                        $0.stage == .hardSafetyRejection
                    }) != true
            else {
                return false
            }
            switch candidate.status {
            case .ready, .needsValidation:
                return true
            case .reviewRequired:
                // Exact planned edits and retained drafts can be proven
                // structurally against the candidate build. They remain
                // review-required because compilation alone does not establish
                // semantic safety.
                return candidate.draftIdentifier != nil
                    || candidate.repairSource == "Apple Foundation Models"
                    || !candidate.repairIdentifiers.isEmpty
            case .verificationFailed, .rejected, .noProposal:
                return false
            }
        }
        var combinedRepairs = output.plan.repairs
        var validatedCandidates = Set<String>()
        var repairIdentifiersByCandidate: [String: Set<String>] = [:]
        var successMessages: [String: String] = [:]
        var failureMessages: [String: String] = [:]
        var skippedMessages: [String: String] = [:]

        for candidate in output.repairCandidates where
            !candidates.contains(where: {
                $0.candidateIdentifier == candidate.candidateIdentifier
            })
        {
            skippedMessages[candidate.candidateIdentifier] =
                automaticValidationSkipReason(
                    candidate,
                    draft: candidate.draftIdentifier.flatMap { drafts[$0] },
                    conflicts: conflictIdentifiers
                )
        }

        progress.message(
            "Automatically validating \(candidates.count) viable repair "
                + "proposal\(candidates.count == 1 ? "" : "s")"
        )
        var candidatesRequiringIndividualValidation = candidates
        if validation == nil, candidates.count > 1, !cancellation() {
            let grouped = Dictionary(grouping: candidates) { candidate in
                // Speculative drafts must not make a deterministic evidence
                // batch fall back to repeated whole-project builds.
                candidate.draftIdentifier == nil
                    ? "deterministic"
                    : "draft:\(candidate.candidateIdentifier)"
            }.values.sorted {
                ($0.first?.candidateIdentifier ?? "")
                    < ($1.first?.candidateIdentifier ?? "")
            }
            for group in grouped where group.count > 1 && !cancellation() {
                do {
                    let batched = try validateRepairCandidatesTogether(
                        group,
                        plan: output.plan,
                        drafts: drafts,
                        root: root,
                        workflow: workflow,
                        runner: runner,
                        progress: progress
                    )
                    for candidate in group {
                        guard let repairs = batched[
                            candidate.candidateIdentifier
                        ], !repairs.isEmpty else { continue }
                        combinedRepairs.append(contentsOf: repairs)
                        let identifiers = Set(repairs.map(\.repairIdentifier))
                        validatedCandidates.insert(
                            candidate.candidateIdentifier
                        )
                        repairIdentifiersByCandidate[
                            candidate.candidateIdentifier
                        ] = identifiers
                        successMessages[candidate.candidateIdentifier] =
                            automaticValidationSuccessMessage(repairs)
                    }
                    candidatesRequiringIndividualValidation.removeAll {
                        batched[$0.candidateIdentifier]?.isEmpty == false
                    }
                } catch {
                    progress.message(
                        "Combined repair validation could not prove every "
                            + "proposal in one evidence group; validating that "
                            + "group separately"
                    )
                }
            }
        }
        for (index, candidate) in
            candidatesRequiringIndividualValidation.enumerated()
        {
            while pauseRequested(), !cancellation() {
                Thread.sleep(forTimeInterval: 0.05)
            }
            guard !cancellation() else { break }
            progress.measure(
                completed: index,
                total: candidatesRequiringIndividualValidation.count,
                label: "Repair validation"
            )
            let subject = candidate.location.map {
                "\($0.path):\($0.line ?? 0)"
            } ?? candidate.title
            progress.message("Validating \(subject)")
            do {
                let candidateDraft = candidate.draftIdentifier.flatMap {
                    drafts[$0]
                }
                let repairs: [ProposedRepair]
                if let validation {
                    repairs = try validation(candidate, candidateDraft)
                } else {
                    let result = try validateRepairCandidate(
                        plan: output.plan,
                        identifiers: Set(candidate.repairIdentifiers),
                        draft: candidateDraft,
                        candidateIdentifier: candidate.candidateIdentifier,
                        root: root,
                        workflow: workflow,
                        runner: runner,
                        progress: progress
                    )
                    guard case let .repairValidated(_, values, _) = result
                    else {
                        failureMessages[candidate.candidateIdentifier] =
                            "Validation completed without a usable repair result."
                        continue
                    }
                    repairs = values
                }
                guard !repairs.isEmpty else {
                    failureMessages[candidate.candidateIdentifier] =
                        "Validation produced no exact source edit."
                    continue
                }
                combinedRepairs.append(contentsOf: repairs)
                let identifiers = Set(repairs.map(\.repairIdentifier))
                validatedCandidates.insert(candidate.candidateIdentifier)
                repairIdentifiersByCandidate[
                    candidate.candidateIdentifier
                ] = identifiers
                successMessages[candidate.candidateIdentifier] =
                    automaticValidationSuccessMessage(repairs)
            } catch {
                failureMessages[candidate.candidateIdentifier] =
                    automaticValidationFailureMessage(error)
            }
            progress.measure(
                completed: index + 1,
                total: candidatesRequiringIndividualValidation.count,
                label: "Repair validation"
            )
        }

        let repairsByIdentifier = Dictionary(
            combinedRepairs.map { ($0.repairIdentifier, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        let rebuiltPlan = RepairPlanBuilder.build(
            projectRoot: root,
            repairs: repairsByIdentifier.values.sorted {
                $0.repairIdentifier < $1.repairIdentifier
            },
            planningFailures: output.plan.planningFailures,
            generatedAt: output.plan.generatedAt
        )
        let promotedConflictIdentifiers = Set(
            rebuiltPlan.conflicts.flatMap(\.repairIdentifiers)
        )
        let conflictingCandidates = repairIdentifiersByCandidate.compactMap {
            candidateIdentifier, repairIdentifiers in
            repairIdentifiers.isDisjoint(with: promotedConflictIdentifiers)
                ? nil : candidateIdentifier
        }
        for candidateIdentifier in conflictingCandidates {
            validatedCandidates.remove(candidateIdentifier)
            repairIdentifiersByCandidate[candidateIdentifier] = nil
            successMessages[candidateIdentifier] = nil
            failureMessages[candidateIdentifier] =
                "Validation produced an edit that overlaps or contradicts "
                + "another proposal. The conflict must be resolved before "
                + "selection."
        }
        let rebuiltOutput = RepairPlanningOutput(
            plan: rebuiltPlan,
            referenceResolutionCoverage:
                output.referenceResolutionCoverage,
            offeredFindingIdentifiers: output.offeredFindingIdentifiers,
            offeredFindingOccurrences: output.offeredFindingOccurrences,
            findingDispositions: output.findingDispositions,
            repairCoverage: output.repairCoverage,
            foundationModelSummary: output.foundationModelSummary,
            repairCandidates: output.repairCandidates,
            repairDrafts: output.repairDrafts
        )
        return TUIPreparedRepairPlan(
            output: rebuiltOutput,
            validatedCandidateIdentifiers: validatedCandidates,
            repairIdentifiersByCandidate: repairIdentifiersByCandidate,
            successMessages: successMessages,
            failureMessages: failureMessages,
            skippedMessages: skippedMessages
        )
    }

    private func automaticValidationSkipReason(
        _ candidate: RepairCandidatePresentation,
        draft: RepairDraft?,
        conflicts: Set<String>
    ) -> String {
        if candidate.edits.isEmpty {
            return "No exact source edit was proposed."
        }
        if candidate.repairIdentifiers.contains(where: conflicts.contains) {
            return "Actual overlapping or contradictory edits must be resolved first."
        }
        if draft?.initialIssues.contains(where: {
            $0.stage == .hardSafetyRejection
        }) == true {
            return "A protected-path or other hard safety check rejected the draft."
        }
        switch candidate.status {
        case .ready:
            return "The proposal is already ready."
        case .needsValidation:
            return "The proposal could not enter isolated validation."
        case .reviewRequired:
            return candidate.repairIdentifiers.isEmpty
                ? "The proposal has no exact planned edit to validate."
                : "The exact planned edit could not enter isolated validation."
        case .verificationFailed:
            return "Candidate-Xcode validation previously failed."
        case .rejected:
            return "A hard safety or structural check rejected the proposal."
        case .noProposal:
            return "No source change is available for this finding."
        }
    }

    private func automaticValidationFailureMessage(_ error: Error) -> String {
        let message = error.localizedDescription.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if message.isEmpty {
            return "Candidate-Xcode validation failed without diagnostic details."
        }
        return "Candidate-Xcode validation failed: \(message)"
    }

    private func automaticValidationSuccessMessage(
        _ repairs: [ProposedRepair]
    ) -> String {
        let semanticReview = repairs.contains {
            $0.requiresReview == true
                || $0.modelGenerated == true
                || $0.safety != .safe
        }
        return "Build Verified. The proposal parsed, the targeted evidence "
            + "disappeared, diagnostics did not regress, and reference coverage "
            + "was preserved in an isolated candidate-Xcode build."
            + (semanticReview
                ? " Needs Semantic Review before selection and Apply."
                : "")
    }

    private func validateRepairCandidatesTogether(
        _ candidates: [RepairCandidatePresentation],
        plan: RepairPlan,
        drafts: [String: RepairDraft],
        root: URL,
        workflow: TUIWorkflowSettings,
        runner: any ProcessRunning,
        progress: OperationProgress
    ) throws -> [String: [ProposedRepair]] {
        let temporary = try TemporaryDirectory(
            prefix: "swiftdelta-isolated-repair-validation"
        )
        defer { temporary.remove() }
        let isolatedRoot = temporary.url.appendingPathComponent(
            "Project",
            isDirectory: true
        )
        try progress.phase(
            "Preparing combined isolated repair validation",
            completedMessage: "Prepared combined isolated repair validation"
        ) {
            try copyProjectForValidation(from: root, to: isolatedRoot)
        }
        let planRepairs = Dictionary(
            plan.repairs.map { ($0.repairIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var repairsByCandidate: [String: [ProposedRepair]] = [:]
        for candidate in candidates {
            let repairs: [ProposedRepair]
            if let draftIdentifier = candidate.draftIdentifier,
               let draft = drafts[draftIdentifier]
            {
                repairs = try RepairDraftNormalizer.normalize(
                    draft,
                    projectRoot: isolatedRoot
                )
            } else {
                repairs = try candidate.repairIdentifiers.map { identifier in
                    guard let repair = planRepairs[identifier] else {
                        throw SwiftDeltaError.invalidConfiguration(
                            field: "repair candidate",
                            reason: "a planned edit is no longer available"
                        )
                    }
                    return validatedCopy(of: repair)
                }
            }
            guard !repairs.isEmpty else {
                throw SwiftDeltaError.invalidConfiguration(
                    field: "repair candidate",
                    reason: "a candidate contains no exact source edit"
                )
            }
            repairsByCandidate[candidate.candidateIdentifier] = repairs
        }
        let combined = repairsByCandidate.values.flatMap { $0 }
        let repairsByIdentifier = Dictionary(
            combined.map { ($0.repairIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let isolatedPlan = RepairPlanBuilder.build(
            projectRoot: isolatedRoot,
            repairs: repairsByIdentifier.values.sorted {
                $0.repairIdentifier < $1.repairIdentifier
            }
        )
        guard isolatedPlan.conflicts.isEmpty else {
            throw SwiftDeltaError.invalidConfiguration(
                field: "repair candidates",
                reason: "the combined proposal set contains conflicting edits"
            )
        }
        _ = try applyRepairs(
            plan: isolatedPlan,
            identifiers: Set(isolatedPlan.repairs.map(\.repairIdentifier)),
            validatedIdentifiers:
                Set(isolatedPlan.repairs.map(\.repairIdentifier)),
            root: isolatedRoot,
            workflow: rebased(
                workflow,
                originalRoot: root,
                isolatedRoot: isolatedRoot
            ),
            runner: runner,
            progress: progress
        )
        return repairsByCandidate
    }

    func applyRepairs(
        plan: RepairPlan,
        identifiers: Set<String>,
        validatedIdentifiers: Set<String> = [],
        root: URL,
        workflow: TUIWorkflowSettings,
        runner: any ProcessRunning,
        progress: OperationProgress
    ) throws -> TUIOperationResult {
        guard !identifiers.isEmpty else {
            throw SwiftDeltaError.missingSelection("repairs to apply")
        }
        let selected = plan.repairs.filter {
            identifiers.contains($0.repairIdentifier)
        }.map {
            validatedIdentifiers.contains($0.repairIdentifier)
                ? transactionallyApplicableCopy(of: $0) : $0
        }
        let applicable = selected.filter {
            $0.safety == .safe
                || $0.isExplicitlyApplicable
        }
        guard applicable.count == selected.count, !applicable.isEmpty else {
            throw SwiftDeltaError.invalidConfiguration(
                field: "repair selection",
                reason:
                    "the selection contains a repair that is not explicitly applicable"
            )
        }
        let configuration = try effectiveConfiguration(
            root: root,
            workflow: workflow,
            forRepair: true
        )
        guard let candidate = configuration.candidateXcodePath else {
            throw SwiftDeltaError.missingSelection("candidate Xcode application")
        }
        let developer = try XcodeInstallation.validate(
            applicationPath: candidate
        )
        let discovery = try ProjectDiscovery().discover(
            root: root,
            excludedPaths: configuration.excludedPaths
        )
        let container = try ProjectDiscovery().selectBuildContainer(
            from: discovery,
            project: configuration.defaultProject,
            workspace: configuration.defaultWorkspace
        )
        let scheme: String
        if container.kind == .package {
            scheme = ""
        } else {
            let details = try XcodeContainerInspector(runner: runner).inspect(
                container,
                developerDirectory: developer,
                timeout: min(workflow.timeout, 30)
            )
            scheme = try ScanEngine().selectScheme(
                configured: configuration.defaultScheme,
                available: details.schemes
            )
        }
        let verifier = CandidateRepairVerifier(
            buildInvocation: BuildInvocation(
                xcodePath: candidate,
                container: container,
                scheme: scheme,
                configuration: workflow.buildConfiguration,
                destination: workflow.destination,
                timeout: workflow.timeout,
                sdkIdentifiers: configuration.sdkIdentifiers
            ),
            planningRequest: RepairPlanningRequest(
                root: root,
                configuration: configuration,
                selectedSourcePaths: Array(
                    Set(applicable.map(\.filePath))
                ).sorted(),
                timeoutPerFile: workflow.timeout,
                sdkCachePolicy: workflow.sdkCachePolicy,
                buildConfiguration: workflow.buildConfiguration,
                destination: workflow.destination
            ),
            builder: XcodeProjectBuilder(runner: runner, progress: progress),
            planner: RepairPlanningEngine(runner: runner, progress: progress),
            requiredEvidenceSources: Set(applicable.map(\.evidenceSource))
        )
        _ = try RepairApplicationService().apply(
            plan: plan,
            selectedRepairs: applicable,
            projectRoot: root,
            verifier: verifier,
            progress: progress
        )
        return .repairsApplied(applicable.count)
    }

    func validateRepairCandidate(
        plan: RepairPlan?,
        identifiers: Set<String>,
        draft: RepairDraft?,
        candidateIdentifier: String,
        root: URL,
        workflow: TUIWorkflowSettings,
        runner: any ProcessRunning,
        progress: OperationProgress
    ) throws -> TUIOperationResult {
        let selected: [ProposedRepair]
        if draft == nil {
            guard !identifiers.isEmpty else {
                throw SwiftDeltaError.missingSelection(
                    "repair candidate edits"
                )
            }
            selected = (plan?.repairs ?? []).filter {
                identifiers.contains($0.repairIdentifier)
            }
            guard selected.count == identifiers.count else {
                throw SwiftDeltaError.invalidConfiguration(
                    field: "repair candidate",
                    reason:
                        "one or more candidate edits are no longer in the plan"
                )
            }
        } else {
            selected = []
        }
        let temporary = try TemporaryDirectory(
            prefix: "swiftdelta-isolated-repair-validation"
        )
        defer { temporary.remove() }
        let isolatedRoot = temporary.url.appendingPathComponent(
            "Project",
            isDirectory: true
        )
        try progress.phase(
            "Preparing isolated repair validation",
            completedMessage: "Prepared isolated repair validation"
        ) {
            try copyProjectForValidation(from: root, to: isolatedRoot)
        }
        let candidateRepairs: [ProposedRepair]
        if let draft {
            candidateRepairs = try progress.phase(
                "Resolving draft repair anchors",
                completedMessage: "Resolved draft repair anchors"
            ) {
                try RepairDraftNormalizer.normalize(
                    draft,
                    projectRoot: isolatedRoot
                )
            }
            guard !candidateRepairs.isEmpty else {
                throw SwiftDeltaError.invalidConfiguration(
                    field: "repair draft",
                    reason: "the draft contains no usable source edit"
                )
            }
        } else {
            candidateRepairs = selected.map(validatedCopy)
        }
        let isolatedPlan = RepairPlanBuilder.build(
            projectRoot: isolatedRoot,
            repairs: candidateRepairs
        )
        guard isolatedPlan.conflicts.isEmpty else {
            throw SwiftDeltaError.invalidConfiguration(
                field: "repair draft",
                reason:
                    "the normalized draft contains overlapping or "
                    + "contradictory edits"
            )
        }
        _ = try applyRepairs(
            plan: isolatedPlan,
            identifiers: Set(isolatedPlan.repairs.map(\.repairIdentifier)),
            validatedIdentifiers:
                Set(isolatedPlan.repairs.map(\.repairIdentifier)),
            root: isolatedRoot,
            workflow: rebased(
                workflow,
                originalRoot: root,
                isolatedRoot: isolatedRoot
            ),
            runner: runner,
            progress: progress
        )
        return .repairValidated(
            candidateIdentifier: candidateIdentifier,
            repairs: candidateRepairs,
            message:
                "The proposal parsed and passed isolated candidate-Xcode "
                + "verification. The original project was not modified."
        )
    }

    private func validatedCopy(of repair: ProposedRepair) -> ProposedRepair {
        ProposedRepair(
            repairIdentifier: repair.repairIdentifier,
            relatedFindingIdentifier: repair.relatedFindingIdentifier,
            evidenceSource: repair.evidenceSource,
            language: repair.language,
            filePath: repair.filePath,
            sourceRange: repair.sourceRange,
            originalText: repair.originalText,
            replacementText: repair.replacementText,
            fileFingerprint: repair.fileFingerprint,
            confidence: repair.confidence,
            safety: repair.safety == .safe ? .safe : .reviewRequired,
            explanation: repair.explanation,
            verificationRequirement: repair.verificationRequirement,
            toolchains: repair.toolchains,
            symbols: repair.symbols,
            compilerContext: repair.compilerContext,
            generatedBy: repair.generatedBy,
            provider: repair.provider,
            execution: repair.execution,
            hostModelGeneration: repair.hostModelGeneration,
            reasoningLevel: repair.reasoningLevel,
            modelGenerated: repair.modelGenerated,
            requiresReview: repair.requiresReview
        )
    }

    private func transactionallyApplicableCopy(
        of repair: ProposedRepair
    ) -> ProposedRepair {
        ProposedRepair(
            repairIdentifier: repair.repairIdentifier,
            relatedFindingIdentifier: repair.relatedFindingIdentifier,
            evidenceSource: repair.evidenceSource,
            language: repair.language,
            filePath: repair.filePath,
            sourceRange: repair.sourceRange,
            originalText: repair.originalText,
            replacementText: repair.replacementText,
            fileFingerprint: repair.fileFingerprint,
            confidence: repair.confidence,
            safety: .safe,
            explanation: repair.explanation,
            verificationRequirement: repair.verificationRequirement,
            toolchains: repair.toolchains,
            symbols: repair.symbols,
            compilerContext: repair.compilerContext,
            generatedBy: repair.generatedBy,
            provider: repair.provider,
            execution: repair.execution,
            hostModelGeneration: repair.hostModelGeneration,
            reasoningLevel: repair.reasoningLevel,
            modelGenerated: repair.modelGenerated,
            requiresReview: repair.requiresReview
        )
    }

    private func copyProjectForValidation(
        from root: URL,
        to destination: URL
    ) throws {
        let fileManager = FileManager.default
        let canonicalRoot = root.standardizedFileURL
            .resolvingSymlinksInPath()
        try fileManager.createDirectory(
            at: destination,
            withIntermediateDirectories: false
        )
        let excludedNames: Set<String> = [
            ".build", ".git", "DerivedData", "xcuserdata",
        ]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isDirectoryKey, .isSymbolicLinkKey,
            ],
            options: [],
            errorHandler: { _, _ in false }
        ) else {
            throw SwiftDeltaError.invalidConfiguration(
                field: "project root",
                reason: "the project cannot be enumerated for isolated validation"
            )
        }
        for case let source as URL in enumerator {
            let sourceValues = try source.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            let resolvedSource = source.standardizedFileURL
                .resolvingSymlinksInPath()
            let rootComponents = canonicalRoot.pathComponents
            let sourceComponents = resolvedSource.pathComponents
            guard sourceComponents.starts(with: rootComponents) else {
                throw SwiftDeltaError.invalidConfiguration(
                    field: "project root",
                    reason:
                        "isolated validation could not normalize "
                        + "\(source.path) relative to the selected project"
                )
            }
            let relative = sourceComponents.dropFirst(
                rootComponents.count
            ).joined(separator: "/")
            guard !relative.isEmpty else { continue }
            let components = relative.split(separator: "/").map(String.init)
            if components.contains(where: excludedNames.contains) {
                if sourceValues.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            let target = destination.appendingPathComponent(relative)
            if sourceValues.isDirectory == true {
                try fileManager.createDirectory(
                    at: target,
                    withIntermediateDirectories: true
                )
            } else {
                try fileManager.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.copyItem(at: source, to: target)
            }
        }
    }

    private func rebased(
        _ workflow: TUIWorkflowSettings,
        originalRoot: URL,
        isolatedRoot: URL
    ) -> TUIWorkflowSettings {
        var result = workflow
        result.projectRoot = isolatedRoot.path
        result.projectPath = rebase(
            workflow.projectPath,
            originalRoot: originalRoot,
            isolatedRoot: isolatedRoot
        )
        result.workspacePath = rebase(
            workflow.workspacePath,
            originalRoot: originalRoot,
            isolatedRoot: isolatedRoot
        )
        return result
    }

    private func rebase(
        _ path: String?,
        originalRoot: URL,
        isolatedRoot: URL
    ) -> String? {
        guard let path else { return nil }
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        let root = originalRoot.standardizedFileURL.path
        guard standardized == root || standardized.hasPrefix(root + "/") else {
            return path
        }
        let relative = standardized.dropFirst(root.count)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return relative.isEmpty
            ? isolatedRoot.path
            : isolatedRoot.appendingPathComponent(relative).path
    }

}
