//===--- RepairFindingDisposition.swift - SwiftDelta ------------------------------------------===//
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

public enum RepairFindingDispositionKind: String, Sendable {
    case automaticallySafe
    case foundationModelsProposal
    case manualReviewRequired
    case notRepairable
}

/// Explains how one occurrence from the completed Analysis result was handled
/// during repair planning. This is runtime planning state and is deliberately
/// separate from the versioned repair-plan file format.
public struct RepairFindingDisposition: Hashable, Sendable {
    public let findingStableKey: String
    public let findingIdentifier: String
    public let title: String
    public let location: SourceLocation?
    public let kind: RepairFindingDispositionKind
    public let reason: String
    public let repairIdentifiers: [String]
    public let hasConflict: Bool

    public init(
        findingStableKey: String,
        findingIdentifier: String,
        title: String,
        location: SourceLocation?,
        kind: RepairFindingDispositionKind,
        reason: String,
        repairIdentifiers: [String] = [],
        hasConflict: Bool = false
    ) {
        self.findingStableKey = findingStableKey
        self.findingIdentifier = findingIdentifier
        self.title = title
        self.location = location
        self.kind = kind
        self.reason = reason
        self.repairIdentifiers = repairIdentifiers.sorted()
        self.hasConflict = hasConflict
    }
}

public struct RepairCoverageSummary: Hashable, Sendable {
    public let findingsReceived: Int
    public let mechanicallyRepairable: Int
    public let modelProposed: Int
    public let reviewOnly: Int
    public let conflicting: Int
    public let unsupported: Int
    public let planningFailures: Int

    public init(
        findingsReceived: Int,
        mechanicallyRepairable: Int,
        modelProposed: Int,
        reviewOnly: Int,
        conflicting: Int,
        unsupported: Int,
        planningFailures: Int
    ) {
        self.findingsReceived = findingsReceived
        self.mechanicallyRepairable = mechanicallyRepairable
        self.modelProposed = modelProposed
        self.reviewOnly = reviewOnly
        self.conflicting = conflicting
        self.unsupported = unsupported
        self.planningFailures = planningFailures
    }
}

public enum RepairFindingDispositionBuilder {
    public static func build(
        findings: [Finding],
        plan: RepairPlan,
        projectRoot: URL,
        modelAssistanceRequested: Bool,
        modelNotRepairableReasons: [String: String] = [:],
        modelSkippedReasons: [String: String] = [:],
        modelDraftFindingStableKeys: Set<String> = [],
        repairFindingStableKeys: [String: String] = [:]
    ) -> (
        dispositions: [RepairFindingDisposition],
        summary: RepairCoverageSummary
    ) {
        let root = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        let conflictIdentifiers = Set(
            plan.conflicts.flatMap(\.repairIdentifiers)
        )
        let dispositions = findings
            .sorted { $0.stableKey < $1.stableKey }
            .map { finding in
                let repairs = plan.repairs.filter {
                    repair(
                        $0,
                        belongsTo: finding,
                        root: root,
                        stableKeys: repairFindingStableKeys
                    )
                }
                let repairIDs = repairs.map(\.repairIdentifier)
                let hasConflict = repairIDs.contains {
                    conflictIdentifiers.contains($0)
                }
                if hasConflict {
                    return RepairFindingDisposition(
                        findingStableKey: finding.stableKey,
                        findingIdentifier: finding.findingID,
                        title: finding.title,
                        location: finding.location,
                        kind: .manualReviewRequired,
                        reason:
                            "Exact repair evidence was found, but overlapping, "
                            + "duplicate, or contradictory edits must be resolved "
                            + "before any application.",
                        repairIdentifiers: repairIDs,
                        hasConflict: true
                    )
                }
                let modelRepairs = repairs.filter {
                    $0.evidenceSource == .foundationModels
                }
                if !modelRepairs.isEmpty {
                    let applicable = modelRepairs.contains(
                        where: \.isExplicitlyApplicable
                    )
                    return RepairFindingDisposition(
                        findingStableKey: finding.stableKey,
                        findingIdentifier: finding.findingID,
                        title: finding.title,
                        location: finding.location,
                        kind: .foundationModelsProposal,
                        reason:
                            "The deterministic stages did not produce a safe "
                            + "repair. The local on-device model proposed "
                            + "\(modelRepairs.count) coordinated exact edit"
                            + (modelRepairs.count == 1 ? "" : "s")
                            + (applicable
                                ? " that require review and candidate-Xcode verification."
                                : " for review; unresolved risk prevents automatic application."),
                        repairIdentifiers:
                            modelRepairs.map(\.repairIdentifier)
                    )
                }
                let safe = repairs.filter {
                    $0.safety == .safe && !$0.modelGenerated.orFalse
                }
                if !safe.isEmpty {
                    return RepairFindingDisposition(
                        findingStableKey: finding.stableKey,
                        findingIdentifier: finding.findingID,
                        title: finding.title,
                        location: finding.location,
                        kind: .automaticallySafe,
                        reason:
                            "Structured compiler or SDK evidence supplied "
                            + "conflict-free exact source edits.",
                        repairIdentifiers: safe.map(\.repairIdentifier)
                    )
                }
                if !repairs.isEmpty {
                    return RepairFindingDisposition(
                        findingStableKey: finding.stableKey,
                        findingIdentifier: finding.findingID,
                        title: finding.title,
                        location: finding.location,
                        kind: .manualReviewRequired,
                        reason:
                            "Exact edit evidence exists, but its safety "
                            + "classification requires review.",
                        repairIdentifiers: repairIDs
                    )
                }
                if modelDraftFindingStableKeys.contains(
                    finding.stableKey
                ) {
                    return RepairFindingDisposition(
                        findingStableKey: finding.stableKey,
                        findingIdentifier: finding.findingID,
                        title: finding.title,
                        location: finding.location,
                        kind: .foundationModelsProposal,
                        reason:
                            "The local on-device model produced a retained "
                            + "draft. Edit or validate it in an isolated "
                            + "project copy before selection."
                    )
                }
                if let failure = matchingFailure(
                    for: finding,
                    failures: plan.planningFailures,
                    root: root
                ) {
                    return RepairFindingDisposition(
                        findingStableKey: finding.stableKey,
                        findingIdentifier: finding.findingID,
                        title: finding.title,
                        location: finding.location,
                        kind: .notRepairable,
                        reason:
                            "Repair evidence collection failed for this finding: "
                            + failure.message
                    )
                }
                if let modelReason = modelNotRepairableReasons[
                    finding.stableKey
                ] {
                    return RepairFindingDisposition(
                        findingStableKey: finding.stableKey,
                        findingIdentifier: finding.findingID,
                        title: finding.title,
                        location: finding.location,
                        kind: .notRepairable,
                        reason:
                            "The local on-device model evaluated this exact "
                            + "finding and returned not repairable: \(modelReason)"
                    )
                }
                if let skipReason = modelSkippedReasons[finding.stableKey] {
                    return RepairFindingDisposition(
                        findingStableKey: finding.stableKey,
                        findingIdentifier: finding.findingID,
                        title: finding.title,
                        location: finding.location,
                        kind: .manualReviewRequired,
                        reason:
                            "No on-device model request was made for this "
                            + "finding: \(skipReason)"
                    )
                }
                let fallback = unsupportedDisposition(
                    for: finding,
                    modelAssistanceRequested: modelAssistanceRequested
                )
                return RepairFindingDisposition(
                    findingStableKey: finding.stableKey,
                    findingIdentifier: finding.findingID,
                    title: finding.title,
                    location: finding.location,
                    kind: fallback.kind,
                    reason: fallback.reason
                )
            }

        return (
            dispositions,
            RepairCoverageSummary(
                findingsReceived: dispositions.count,
                mechanicallyRepairable: dispositions.count {
                    $0.kind == .automaticallySafe && !$0.hasConflict
                },
                modelProposed: dispositions.count {
                    $0.kind == .foundationModelsProposal && !$0.hasConflict
                },
                reviewOnly: dispositions.count {
                    $0.kind == .manualReviewRequired
                },
                conflicting: dispositions.count { $0.hasConflict },
                unsupported: dispositions.count {
                    $0.kind == .notRepairable
                },
                planningFailures: plan.planningFailures.count
            )
        )
    }

    private static func repair(
        _ repair: ProposedRepair,
        belongsTo finding: Finding,
        root: URL,
        stableKeys: [String: String]
    ) -> Bool {
        guard repair.relatedFindingIdentifier == finding.findingID else {
            return false
        }
        if let stableKey = stableKeys[repair.repairIdentifier] {
            return stableKey == finding.stableKey
        }
        if let target = finding.target,
           let repairTarget = repair.compilerContext?.target,
           target != repairTarget
        {
            return false
        }
        guard let location = finding.location else {
            return true
        }
        let repairPath = canonical(repair.filePath, root: root)
        let findingPath = canonical(location.path, root: root)
        guard repairPath == findingPath else {
            return false
        }
        guard let line = location.line else {
            return true
        }
        return repair.sourceRange.start.line <= line
            && line <= repair.sourceRange.end.line
    }

    private static func matchingFailure(
        for finding: Finding,
        failures: [AnalysisFailure],
        root: URL
    ) -> AnalysisFailure? {
        guard let location = finding.location else { return nil }
        return failures.first { failure in
            guard let failureLocation = failure.location,
                  canonical(failureLocation.path, root: root)
                    == canonical(location.path, root: root)
            else {
                return false
            }
            return failureLocation.line == nil
                || location.line == nil
                || failureLocation.line == location.line
        }
    }

    private static func unsupportedDisposition(
        for finding: Finding,
        modelAssistanceRequested: Bool
    ) -> (kind: RepairFindingDispositionKind, reason: String) {
        switch finding.origin {
        case .buildSettings:
            return (
                .notRepairable,
                "The evidence describes an effective build-setting difference, "
                    + "but no compiler-proven source edit exists and project "
                    + "metadata remains protected."
            )
        case .package:
            return (
                .notRepairable,
                "Package manifests, resolved dependencies, and dependency source "
                    + "are protected from automatic repair."
            )
        case .compiler, .sdk:
            break
        }
        guard finding.location != nil else {
            return (
                .notRepairable,
                "The finding has no exact editable source location. SwiftDelta "
                    + "does not modify build settings, project metadata, package "
                    + "manifests, dependencies, or generated build artifacts."
            )
        }
        switch finding.origin {
        case .compiler:
            return (
                .manualReviewRequired,
                "The candidate compiler reported the issue but did not provide "
                    + "a uniquely associated structured fix-it with an exact "
                    + "source range."
            )
        case .buildSettings, .package:
            preconditionFailure("Handled before source-location validation")
        case .sdk:
            guard let evidence = finding.sdkEvidence else {
                return (
                    .manualReviewRequired,
                    "The SDK finding does not retain the stable symbol and "
                        + "declaration evidence required for an exact edit."
                )
            }
            if evidence.resolutionMethod != .compilerUSR {
                return (
                    .manualReviewRequired,
                    "The source reference was not resolved to a stable compiler "
                        + "symbol identity, so a textual edit would be unsafe."
                )
            }
            if finding.severity == .notice,
               isInformationalMetadataChange(evidence.changeKind)
            {
                return (
                    .notRepairable,
                    "No source change is required by current compiler "
                        + "evidence. The SDK metadata difference remains "
                        + "visible in Analysis but is not an actionable repair."
                )
            }
            let modelSuffix = modelAssistanceRequested
                ? " The local model did not produce a validated exact proposal."
                : ""
            return (
                .manualReviewRequired,
                "The \(evidence.changeKind.rawValue) change requires source-level "
                    + "judgment or lacks one unambiguous mechanically compatible "
                    + "replacement.\(modelSuffix)"
            )
        }
    }

    private static func isInformationalMetadataChange(
        _ kind: SDKChangeKind
    ) -> Bool {
        switch kind {
        case .newlyDeprecated, .availabilityChanged,
             .concurrencyChanged, .propertyAccessChanged,
             .protocolRequirementChanged, .inheritanceChanged,
             .conformanceChanged:
            true
        case .removed, .newlyUnavailable, .renamed,
             .signatureChanged, .parameterLabelsChanged,
             .parameterTypesChanged, .returnTypeChanged:
            false
        }
    }

    private static func canonical(_ path: String, root: URL) -> String {
        let url = NSString(string: path).isAbsolutePath
            ? URL(fileURLWithPath: path)
            : root.appendingPathComponent(path)
        return url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

private extension Optional where Wrapped == Bool {
    var orFalse: Bool { self ?? false }
}
