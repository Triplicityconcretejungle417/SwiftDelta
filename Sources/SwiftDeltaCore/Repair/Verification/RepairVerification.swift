//===--- RepairVerification.swift - SwiftDelta ------------------------------------------===//
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

public struct RepairFindingOccurrence: Hashable, Sendable {
    public let findingIdentifier: String
    public let stableKey: String
    public let filePath: String?
    public let line: Int?
    public let column: Int?

    public init(
        findingIdentifier: String,
        stableKey: String,
        filePath: String? = nil,
        line: Int? = nil,
        column: Int? = nil
    ) {
        self.findingIdentifier = findingIdentifier
        self.stableKey = stableKey
        self.filePath = filePath
        self.line = line
        self.column = column
    }

    public init(_ finding: Finding) {
        self.init(
            findingIdentifier: finding.findingID,
            stableKey: finding.stableKey,
            filePath: finding.location?.path,
            line: finding.location?.line,
            column: finding.location?.column
        )
    }
}

public struct RepairVerificationSnapshot: Sendable {
    public let buildSucceeded: Bool
    public let diagnostics: [CompilerDiagnostic]
    public let offeredFindingIdentifiers: Set<String>
    public let offeredFindingOccurrences: Set<RepairFindingOccurrence>
    public let unresolvedReferenceCount: Int
    public let failedReferenceFileCount: Int
    public let referenceResolutionCoverage: [ReferenceResolutionCoverage]
    public let buildContextIdentity: String?

    public init(
        buildSucceeded: Bool,
        diagnostics: [CompilerDiagnostic],
        offeredFindingIdentifiers: Set<String>,
        offeredFindingOccurrences: Set<RepairFindingOccurrence> = [],
        unresolvedReferenceCount: Int = 0,
        failedReferenceFileCount: Int = 0,
        referenceResolutionCoverage: [ReferenceResolutionCoverage] = [],
        buildContextIdentity: String? = nil
    ) {
        self.buildSucceeded = buildSucceeded
        self.diagnostics = diagnostics
        self.offeredFindingIdentifiers = offeredFindingIdentifiers
        self.offeredFindingOccurrences = offeredFindingOccurrences
        self.unresolvedReferenceCount = unresolvedReferenceCount
        self.failedReferenceFileCount = failedReferenceFileCount
        self.referenceResolutionCoverage = referenceResolutionCoverage
        self.buildContextIdentity = buildContextIdentity
    }
}

public protocol RepairVerifying: Sendable {
    func capture() throws -> RepairVerificationSnapshot
}

public struct CandidateRepairVerifier: RepairVerifying {
    private let buildInvocation: BuildInvocation
    private let planningRequest: RepairPlanningRequest
    private let builder: any ProjectBuilding
    private let planner: RepairPlanningEngine

    public init(
        buildInvocation: BuildInvocation,
        planningRequest: RepairPlanningRequest,
        builder: any ProjectBuilding = XcodeProjectBuilder(),
        planner: RepairPlanningEngine = RepairPlanningEngine(),
        requiredEvidenceSources: Set<RepairEvidenceSource>? = nil
    ) {
        self.buildInvocation = buildInvocation
        self.planningRequest = planningRequest
        self.builder = builder
        self.planner = planner
        _ = requiredEvidenceSources
    }

    public func capture() throws -> RepairVerificationSnapshot {
        let build = try builder.build(buildInvocation, cancellation: { false })
        let evidence = try evidencePlan()
        let plan = evidence.plan
        var occurrences = evidence.offeredFindingOccurrences
        for repair in plan.repairs where !occurrences.contains(where: {
            $0.findingIdentifier == repair.relatedFindingIdentifier
                && sameSourcePath($0.filePath, repair.filePath)
                && $0.line == repair.sourceRange.start.line
        }) {
            occurrences.insert(
                RepairFindingOccurrence(
                    findingIdentifier: repair.relatedFindingIdentifier,
                    stableKey: [
                        repair.relatedFindingIdentifier,
                        repair.filePath,
                        String(repair.sourceRange.start.line),
                        String(repair.sourceRange.start.column),
                    ].joined(separator: "|"),
                    filePath: repair.filePath,
                    line: repair.sourceRange.start.line,
                    column: repair.sourceRange.start.column
                )
            )
        }
        let unresolved = plan.planningFailures.count {
            $0.message.contains("were unresolved and excluded")
        }
        let failedFiles = plan.planningFailures.count {
            $0.message.contains("Could not resolve SDK symbol references")
        }
        return RepairVerificationSnapshot(
            buildSucceeded: build.succeeded,
            diagnostics: build.diagnostics,
            offeredFindingIdentifiers:
                evidence.offeredFindingIdentifiers.union(
                    plan.repairs.map(\.relatedFindingIdentifier)
                ),
            offeredFindingOccurrences: occurrences,
            unresolvedReferenceCount: unresolved,
            failedReferenceFileCount: failedFiles,
            referenceResolutionCoverage:
                evidence.referenceResolutionCoverage.filter {
                    $0.toolchainRole == "candidate"
                },
            buildContextIdentity: buildContextIdentity
        )
    }

    private func sameSourcePath(_ lhs: String?, _ rhs: String) -> Bool {
        guard let lhs else { return false }
        return lhs == rhs || lhs.hasSuffix("/\(rhs)")
    }

    private var buildContextIdentity: String {
        [
            buildInvocation.xcodePath,
            buildInvocation.container.kind.rawValue,
            buildInvocation.container.path,
            buildInvocation.scheme,
            buildInvocation.configuration ?? "",
            buildInvocation.destination ?? "",
            buildInvocation.sdkIdentifiers.joined(separator: ","),
        ].joined(separator: "|")
    }

    private func evidencePlan() throws -> RepairPlanningOutput {
        // Verification must repeat the same target-aware analysis used for
        // planning. A cheaper per-file compiler pass cannot prove that the
        // target, module, imports, or diagnostic disappeared for the right
        // reason.
        try planner.planWithEvidence(planningRequest)
    }
}

public struct RepairApplicationResult: Sendable {
    public let appliedRepairIdentifiers: [String]
    public let verificationBefore: RepairVerificationSnapshot
    public let verificationAfter: RepairVerificationSnapshot

    public init(
        appliedRepairIdentifiers: [String],
        verificationBefore: RepairVerificationSnapshot,
        verificationAfter: RepairVerificationSnapshot
    ) {
        self.appliedRepairIdentifiers = appliedRepairIdentifiers
        self.verificationBefore = verificationBefore
        self.verificationAfter = verificationAfter
    }
}

public struct RepairApplicationService: Sendable {
    public init() {}

    public func apply(
        plan: RepairPlan,
        selectedRepairs: [ProposedRepair],
        projectRoot: URL,
        verifier: any RepairVerifying,
        progress: OperationProgress = .silent
    ) throws -> RepairApplicationResult {
        let canonicalRoot = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        guard canonicalRoot.path == URL(
            fileURLWithPath: plan.projectRoot,
            isDirectory: true
        ).standardizedFileURL.resolvingSymlinksInPath().path else {
            throw RepairError.invalidPlan(
                "the plan project root does not match the selected project root"
            )
        }
        guard !selectedRepairs.isEmpty,
              selectedRepairs.allSatisfy(\.isExplicitlyApplicable)
        else {
            throw RepairError.noSafeSelection
        }
        let selectedIDs = Set(selectedRepairs.map(\.repairIdentifier))
        let planByID = Dictionary(
            plan.repairs.map { ($0.repairIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        guard selectedRepairs.allSatisfy({ repair in
            planByID[repair.repairIdentifier] == repair
        }) else {
            throw RepairError.invalidPlan(
                "the selection contains an edit that does not exactly match "
                    + "the current repair plan"
            )
        }
        let selectedConflicts = plan.conflicts.filter {
            Set($0.repairIdentifiers).intersection(selectedIDs).count > 1
        }
        guard selectedConflicts.isEmpty else {
            throw RepairError.conflict(
                Array(Set(selectedConflicts.flatMap(\.repairIdentifiers))).sorted()
            )
        }

        let before = try progress.phase(
            "Capturing candidate diagnostics before repair",
            completedMessage: "Captured candidate diagnostics before repair"
        ) {
            try verifier.capture()
        }
        if !before.referenceResolutionCoverage.isEmpty,
           !hasUsablePreRepairCoverage(
                before.referenceResolutionCoverage,
                selectedRepairs: selectedRepairs
           )
        {
            throw RepairError.verificationFailed(
                "candidate reference analysis did not successfully account for "
                    + "every selected source file before any file was modified"
            )
        }
        let targetedFindings = Set(
            selectedRepairs.map(\.relatedFindingIdentifier)
        )
        guard targetedFindings.isSubset(
            of: before.offeredFindingIdentifiers
        ) else {
            throw RepairError.verificationFailed(
                "the targeted structured repair evidence was not present "
                    + "before application"
            )
        }
        let transaction = try progress.phase(
            "Applying repair transaction",
            completedMessage: "Applied repair transaction"
        ) {
            try RepairTransaction().apply(
                repairs: selectedRepairs,
                projectRoot: canonicalRoot
            )
        }
        do {
            let after = try progress.phase(
                "Verifying repaired sources with the candidate toolchain",
                completedMessage: "Verified repaired sources with the candidate toolchain"
            ) {
                try verifier.capture()
            }
            try validate(
                before: before,
                after: after,
                selectedRepairs: selectedRepairs
            )
            transaction.finish()
            return RepairApplicationResult(
                appliedRepairIdentifiers: selectedRepairs
                    .map(\.repairIdentifier).sorted(),
                verificationBefore: before,
                verificationAfter: after
            )
        } catch {
            let verificationError = error
            progress.message("Verification failed; rolling back the repair transaction")
            do {
                try transaction.rollback()
                progress.message("Restored all modified source files")
            } catch let rollbackError {
                throw RepairError.rollbackFailed(
                    "verification failed: \(verificationError.localizedDescription); "
                        + "rollback also failed: \(rollbackError.localizedDescription)"
                )
            }
            throw RepairError.verificationFailed(
                verificationError.localizedDescription
            )
        }
    }

    private func validate(
        before: RepairVerificationSnapshot,
        after: RepairVerificationSnapshot,
        selectedRepairs: [ProposedRepair]
    ) throws {
        let targetedFindings = Set(
            selectedRepairs.map(\.relatedFindingIdentifier)
        )
        let targetedOccurrences = occurrenceKeys(
            for: selectedRepairs,
            in: before.offeredFindingOccurrences
        )
        let occurrenceBackedRepairIDs = Set(targetedOccurrences.keys)
        let identifiersRequiringFallback = targetedFindings.subtracting(
            occurrenceBackedRepairIDs
        )
        guard identifiersRequiringFallback.isSubset(
            of: before.offeredFindingIdentifiers
        ), selectedRepairs.allSatisfy({ repair in
            targetedOccurrences[repair.relatedFindingIdentifier] != nil
                || before.offeredFindingIdentifiers.contains(
                    repair.relatedFindingIdentifier
                )
        }) else {
            throw RepairVerificationRejection(
                "the targeted structured repair evidence was not present "
                    + "before application"
            )
        }
        if let beforeIdentity = before.buildContextIdentity,
           let afterIdentity = after.buildContextIdentity,
           beforeIdentity != afterIdentity
        {
            throw RepairVerificationRejection(
                "candidate verification used a different target or build context"
            )
        }
        let remainingOccurrenceKeys = Set(
            after.offeredFindingOccurrences.map(\.stableKey)
        )
        let unresolvedOccurrences = targetedOccurrences.values
            .flatMap { $0 }
            .filter(remainingOccurrenceKeys.contains)
        let unresolvedFallback = identifiersRequiringFallback.intersection(
            after.offeredFindingIdentifiers
        )
        guard unresolvedOccurrences.isEmpty, unresolvedFallback.isEmpty else {
            let unresolved = Set(unresolvedOccurrences).union(
                unresolvedFallback
            )
            throw RepairVerificationRejection(
                "targeted repair evidence remains after the edit: "
                    + unresolved.sorted().joined(separator: ", ")
            )
        }
        if before.buildSucceeded, !after.buildSucceeded {
            throw RepairVerificationRejection(
                "the candidate build succeeded before repair and failed afterward"
            )
        }
        let beforeByMeaning = Dictionary(
            grouping: before.diagnostics,
            by: diagnosticMeaning
        )
        for diagnostic in after.diagnostics {
            let previous = beforeByMeaning[diagnosticMeaning(diagnostic)] ?? []
            if previous.isEmpty, diagnostic.severity.isAtLeast(.warning) {
                throw RepairVerificationRejection(
                    "a new \(diagnostic.severity.rawValue) was introduced: \(diagnostic.message)"
                )
            }
            if let previousRank = previous.map(\.severity.rank).max(),
               diagnostic.severity.rank > previousRank
            {
                throw RepairVerificationRejection(
                    "a diagnostic increased in severity: \(diagnostic.message)"
                )
            }
        }
        if !before.referenceResolutionCoverage.isEmpty
            || !after.referenceResolutionCoverage.isEmpty
        {
            try validateCoverage(
                before: before.referenceResolutionCoverage,
                after: after.referenceResolutionCoverage,
                selectedRepairs: selectedRepairs
            )
        } else {
            guard after.unresolvedReferenceCount <= before.unresolvedReferenceCount,
                  after.failedReferenceFileCount <= before.failedReferenceFileCount
            else {
                throw RepairVerificationRejection(
                    "compiler symbol-resolution coverage regressed after repair"
                )
            }
        }
    }

    private func occurrenceKeys(
        for repairs: [ProposedRepair],
        in occurrences: Set<RepairFindingOccurrence>
    ) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for repair in repairs {
            let matches = occurrences.filter { occurrence in
                guard occurrence.findingIdentifier
                    == repair.relatedFindingIdentifier,
                    sameSourcePath(occurrence.filePath, repair.filePath),
                    let line = occurrence.line
                else { return false }
                return line >= repair.sourceRange.start.line
                    && line <= repair.sourceRange.end.line
            }
            if !matches.isEmpty {
                result[repair.relatedFindingIdentifier, default: []]
                    .formUnion(matches.map(\.stableKey))
            }
        }
        return result
    }

    private func sameSourcePath(_ lhs: String?, _ rhs: String) -> Bool {
        guard let lhs else { return false }
        return lhs == rhs || lhs.hasSuffix("/\(rhs)")
    }

    private func validateCoverage(
        before: [ReferenceResolutionCoverage],
        after: [ReferenceResolutionCoverage],
        selectedRepairs: [ProposedRepair]
    ) throws {
        func key(_ value: ReferenceResolutionCoverage) -> String {
            [
                value.toolchainRole ?? "",
                value.sdkIdentifier,
                value.scheme ?? "",
                value.target ?? "",
                value.configuration ?? "",
                value.destination ?? "",
                value.architecture ?? "",
                value.deploymentTarget ?? "",
            ].joined(separator: "|")
        }
        func contexts(
            _ values: [ReferenceResolutionCoverage],
            phase: String
        ) throws -> [String: ReferenceResolutionCoverage] {
            var result: [String: ReferenceResolutionCoverage] = [:]
            for value in values {
                let identity = key(value)
                guard result[identity] == nil else {
                    throw RepairVerificationRejection(
                        "\(phase) reference analysis produced duplicate "
                            + "build context \(identity)"
                    )
                }
                result[identity] = value
            }
            return result
        }
        let beforeByContext = try contexts(before, phase: "pre-repair")
        let afterByContext = try contexts(after, phase: "post-repair")
        guard Set(beforeByContext.keys) == Set(afterByContext.keys) else {
            throw RepairVerificationRejection(
                "reference analysis lost or changed a target build context"
            )
        }
        let selectedPaths = Set(selectedRepairs.map(\.filePath))
        var successfullyVerifiedPaths = Set<String>()
        for (identity, baseline) in beforeByContext {
            guard let candidate = afterByContext[identity] else {
                throw RepairVerificationRejection(
                    "reference analysis lost context \(identity)"
                )
            }
            let regressions = coverageRegressions(
                before: baseline,
                after: candidate,
                permittedStableIdentityReduction: selectedRepairs.count
            )
            guard regressions.isEmpty else {
                throw RepairVerificationRejection(
                    "reference coverage regressed for context \(identity): "
                        + regressions.joined(separator: "; ")
                )
            }
            for path in selectedPaths {
                let beforeRecord = sourceRecord(
                    path,
                    in: baseline.sourceFiles
                )
                let afterRecord = sourceRecord(
                    path,
                    in: candidate.sourceFiles
                )
                if beforeRecord?.disposition.isSuccessful == true,
                   afterRecord?.disposition.isSuccessful == true
                {
                    successfullyVerifiedPaths.insert(path)
                }
            }
        }
        let missing = selectedPaths.subtracting(successfullyVerifiedPaths)
        guard missing.isEmpty else {
            throw RepairVerificationRejection(
                "selected source files were not analyzed successfully before "
                    + "and after repair: \(missing.sorted().joined(separator: ", "))"
            )
        }
    }

    private func coverageRegressions(
        before: ReferenceResolutionCoverage,
        after: ReferenceResolutionCoverage,
        permittedStableIdentityReduction: Int
    ) -> [String] {
        var reasons: [String] = []
        if !after.isComplete {
            reasons.append(
                "post-repair analysis was incomplete "
                    + "(compiler status \(after.compilerExitStatus.map(String.init) ?? "missing"))"
            )
        }
        if before.filesAnalyzed != before.filesRequested
            || before.filesFailed != 0
        {
            reasons.append(
                "pre-repair file coverage was "
                    + "\(before.filesAnalyzed)/\(before.filesRequested) "
                    + "with \(before.filesFailed) failed"
            )
        }
        if after.filesAnalyzed < before.filesAnalyzed {
            reasons.append(
                "analyzed files decreased from \(before.filesAnalyzed) "
                    + "to \(after.filesAnalyzed)"
            )
        }
        if after.filesFailed > before.filesFailed {
            reasons.append(
                "failed files increased from \(before.filesFailed) "
                    + "to \(after.filesFailed)"
            )
        }
        if after.unresolvedReferences > before.unresolvedReferences {
            reasons.append(
                "unresolved references increased from "
                    + "\(before.unresolvedReferences) to \(after.unresolvedReferences)"
            )
        }
        let minimumStable = max(
            0,
            before.stableIdentityReferences
                - permittedStableIdentityReduction
        )
        if after.stableIdentityReferences < minimumStable {
            reasons.append(
                "stable identities decreased from "
                    + "\(before.stableIdentityReferences) to "
                    + "\(after.stableIdentityReferences), below the permitted "
                    + "minimum \(minimumStable)"
            )
        }
        return reasons
    }

    private func hasUsablePreRepairCoverage(
        _ coverage: [ReferenceResolutionCoverage],
        selectedRepairs: [ProposedRepair]
    ) -> Bool {
        guard !coverage.isEmpty,
              coverage.allSatisfy({
                  $0.filesAnalyzed == $0.filesRequested
                      && $0.filesFailed == 0
              })
        else {
            return false
        }
        return selectedRepairs.allSatisfy { repair in
            coverage.contains { context in
                sourceRecord(
                    repair.filePath,
                    in: context.sourceFiles
                )?.disposition.isSuccessful == true
            }
        }
    }

    private func sourceRecord(
        _ relativePath: String,
        in records: [SourceAnalysisRecord]
    ) -> SourceAnalysisRecord? {
        records.first {
            $0.path == relativePath || $0.path.hasSuffix("/\(relativePath)")
        }
    }

    private func diagnosticMeaning(_ diagnostic: CompilerDiagnostic) -> String {
        diagnostic.deduplicationKey
    }
}

private struct RepairVerificationRejection: LocalizedError {
    let reason: String

    init(_ reason: String) {
        self.reason = reason
    }

    var errorDescription: String? {
        reason
    }
}
