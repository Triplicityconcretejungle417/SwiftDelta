//===--- SDKProjectMatcher.swift - SwiftDelta ------------------------------------------===//
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

/// Restricts SDK changes to compiler-resolved references from project source.
///
/// Unqualified textual names are never lookup keys. References without a USR
/// must contain both a module and a fully qualified symbol name.
public enum SDKProjectMatcher {
    public static func findings(
        changes: [SDKSymbolChange],
        references: [SDKSymbolReference],
        candidateReferences: [SDKSymbolReference] = [],
        candidateDiagnostics: [CompilerDiagnostic] = [],
        candidateCompleteTargets: Set<String>? = nil,
        baseline: SDKSnapshot,
        candidate: SDKSnapshot
    ) -> [Finding] {
        let activeReferences = references.filter(\.isActiveCompilationBranch)
        let candidateSDKIdentities = Set(
            candidate.symbols.compactMap(\.preciseIdentifier)
        )
        let activeCandidateReferences = candidateReferences.filter(
            \.isActiveCompilationBranch
        ).filter {
            guard let identity = $0.preciseIdentifier else { return false }
            return candidateSDKIdentities.contains(identity)
        }
        let changesByUSR = Dictionary(
            grouping: changes.filter { $0.baseline.preciseIdentifier != nil },
            by: { $0.baseline.preciseIdentifier! }
        )
        let changesByQualifiedName = Dictionary(
            grouping: changes,
            by: { "\($0.baseline.moduleName)|\($0.baseline.fullyQualifiedName)" }
        )
        var findings: [Finding] = []

        for reference in activeReferences {
            let matches: [SDKSymbolChange]
            let resolutionConfidence: Confidence
            if let preciseIdentifier = reference.preciseIdentifier {
                matches = changesByUSR[preciseIdentifier] ?? []
                resolutionConfidence = .high
            } else if let module = reference.moduleName,
                      let qualifiedName = reference.fullyQualifiedName
            {
                matches = changesByQualifiedName["\(module)|\(qualifiedName)"] ?? []
                resolutionConfidence = reference.resolutionMethod == .uncertainText ? .low : .medium
            } else {
                continue
            }

            for change in consolidated(matches) {
                if requiresCandidateSourceEvidence(change.kind),
                   let candidateCompleteTargets,
                   reference.target.map(candidateCompleteTargets.contains) != true
                {
                    continue
                }
                let candidateAccepted = activeCandidateReferences.contains {
                    sameSourceExpression($0.sourceLocation, reference.sourceLocation)
                        && $0.target == reference.target
                        && $0.preciseIdentifier != nil
                }
                if change.kind == .removed, candidateAccepted {
                    continue
                }
                let compilerConfirmsRemoval = change.kind == .removed
                    && candidateDiagnostics.contains {
                        $0.severity == .error
                            && ($0.target == nil || $0.target == reference.target)
                            && sameSourceExpression(
                                $0.location,
                                reference.sourceLocation
                            )
                    }
                let evidenceConfidence = change.kind == .removed
                    && !compilerConfirmsRemoval
                    ? Confidence.low
                    : change.matchConfidence
                let confidence = minimum(
                    evidenceConfidence,
                    resolutionConfidence
                )
                let migrationMessage = migrationMessage(
                    for: change,
                    platform: baseline.identity.platform
                )
                let oldAvailability = SDKSnapshotDiffer.relevantAvailability(
                    change.baseline.availability,
                    platform: baseline.identity.platform
                )
                let newAvailability = SDKSnapshotDiffer.relevantAvailability(
                    change.candidate?.availability ?? [],
                    platform: baseline.identity.platform
                )
                let evidence = SDKFindingEvidence(
                    baseline: baseline.identity,
                    candidate: candidate.identity,
                    platform: baseline.identity.platform,
                    moduleName: change.baseline.moduleName,
                    preciseIdentifier: change.baseline.preciseIdentifier,
                    fullyQualifiedName: change.baseline.fullyQualifiedName,
                    sourceLocation: reference.sourceLocation,
                    changeKind: change.kind,
                    observedChange: change.observedChange,
                    oldDeclaration: change.baseline.declaration,
                    newDeclaration: replacementDeclaration(
                        for: change,
                        candidateSymbols: candidate.symbols
                    ),
                    oldAvailability: oldAvailability,
                    newAvailability: newAvailability,
                    migrationMessage: migrationMessage,
                    resolutionMethod: reference.resolutionMethod
                )
                findings.append(
                    Finding(
                        findingID: "sdk.\(change.kind.rawValue).\(change.baseline.id)",
                        category: .sdk,
                        title: title(for: change),
                        explanation: explanation(
                            for: change,
                            baseline: baseline.identity,
                            candidate: candidate.identity,
                            resolutionMethod: reference.resolutionMethod
                        ),
                        severity: severity(
                            for: change,
                            candidateAccepted: candidateAccepted,
                            compilerConfirmsRemoval: compilerConfirmsRemoval
                        ),
                        confidence: confidence,
                        location: reference.sourceLocation,
                        targetVersion: candidate.identity.xcodeVersion,
                        migrationMessage: migrationMessage,
                        origin: .sdk,
                        target: reference.target,
                        sdkEvidence: evidence
                    )
                )
            }
        }
        return FindingMerger.merge(findings)
    }

    private static func requiresCandidateSourceEvidence(
        _ kind: SDKChangeKind
    ) -> Bool {
        switch kind {
        case .removed, .signatureChanged, .parameterLabelsChanged,
             .parameterTypesChanged, .returnTypeChanged,
             .propertyAccessChanged, .protocolRequirementChanged,
             .inheritanceChanged, .conformanceChanged, .concurrencyChanged:
            true
        case .newlyDeprecated, .newlyUnavailable, .renamed,
             .availabilityChanged:
            false
        }
    }

    private static func title(for change: SDKSymbolChange) -> String {
        switch change.kind {
        case .removed: "SDK API removed"
        case .newlyDeprecated: "SDK API newly deprecated"
        case .newlyUnavailable: "SDK API newly unavailable"
        case .renamed: "SDK API renamed"
        case .signatureChanged: "SDK API signature changed"
        case .parameterLabelsChanged: "SDK API parameter labels changed"
        case .parameterTypesChanged: "SDK API parameter types changed"
        case .returnTypeChanged: "SDK API return type changed"
        case .availabilityChanged: "SDK API availability changed"
        case .propertyAccessChanged: "SDK property access changed"
        case .protocolRequirementChanged: "SDK protocol requirement changed"
        case .inheritanceChanged: "SDK inheritance changed"
        case .conformanceChanged: "SDK conformance changed"
        case .concurrencyChanged: "SDK concurrency annotation changed"
        }
    }

    private static func explanation(
        for change: SDKSymbolChange,
        baseline: SDKInstallationIdentity,
        candidate: SDKInstallationIdentity,
        resolutionMethod: SymbolResolutionMethod
    ) -> String {
        let uncertainty = resolutionMethod == .uncertainText
            ? " The project reference could not be resolved to a compiler USR and is explicitly uncertain."
            : ""
        return [
            change.observedChange,
            "Observed in \(change.baseline.moduleName) for \(baseline.platform), comparing Xcode \(baseline.xcodeVersion) (\(baseline.xcodeBuild)) SDK \(baseline.sdkVersion) with Xcode \(candidate.xcodeVersion) (\(candidate.xcodeBuild)) SDK \(candidate.sdkVersion).\(uncertainty)",
        ].joined(separator: " ")
    }

    private static func severity(
        for change: SDKSymbolChange,
        candidateAccepted: Bool,
        compilerConfirmsRemoval: Bool
    ) -> Severity {
        switch change.kind {
        case .removed:
            if compilerConfirmsRemoval, change.matchConfidence == .high {
                return .error
            }
            return change.matchConfidence == .medium ? .warning : .notice
        case .newlyUnavailable:
            return .error
        case .newlyDeprecated, .renamed, .signatureChanged, .parameterLabelsChanged,
             .parameterTypesChanged, .returnTypeChanged, .propertyAccessChanged,
             .protocolRequirementChanged, .inheritanceChanged, .conformanceChanged:
            return candidateAccepted ? .notice : .warning
        case .concurrencyChanged:
            return isConcurrencyRelaxation(change) || candidateAccepted
                ? .notice
                : .warning
        case .availabilityChanged:
            return .notice
        }
    }

    private static func migrationMessage(
        for change: SDKSymbolChange,
        platform: String
    ) -> String? {
        switch change.kind {
        case .newlyDeprecated, .newlyUnavailable, .renamed:
            let candidateAvailability = SDKSnapshotDiffer.relevantAvailability(
                change.candidate?.availability ?? [],
                platform: platform
            )
            let baselineAvailability = SDKSnapshotDiffer.relevantAvailability(
                change.baseline.availability,
                platform: platform
            )
            return candidateAvailability.compactMap(\.message).first
                ?? baselineAvailability.compactMap(\.message).first
                ?? (candidateAvailability.isEmpty
                    && change.candidate?.availability.isEmpty == true
                    ? change.candidate?.migrationMessage
                    : nil)
                ?? (baselineAvailability.isEmpty
                    && change.baseline.availability.isEmpty
                    ? change.baseline.migrationMessage
                    : nil)
        case .removed, .signatureChanged, .parameterLabelsChanged,
             .parameterTypesChanged, .returnTypeChanged, .availabilityChanged,
             .propertyAccessChanged, .protocolRequirementChanged,
             .inheritanceChanged, .conformanceChanged, .concurrencyChanged:
            return nil
        }
    }

    private static func replacementDeclaration(
        for change: SDKSymbolChange,
        candidateSymbols: [SDKSymbol]
    ) -> String? {
        guard change.kind == .renamed else {
            return change.candidate?.declaration
        }
        let destination = change.candidate.flatMap(
            SDKRenameResolver.destination
        ) ?? SDKRenameResolver.destination(for: change.baseline)
        guard let destination,
              let replacement = SDKRenameResolver.uniqueDestination(
                  for: change.baseline,
                  destination: destination,
                  in: candidateSymbols
              )
        else {
            return change.candidate?.declaration
        }
        return replacement.declaration
    }

    private static func isConcurrencyRelaxation(_ change: SDKSymbolChange) -> Bool {
        guard let candidate = change.candidate else { return false }
        let old = change.baseline.concurrency
        let new = candidate.concurrency
        if old.actorIsolation != nil, new.actorIsolation == nil {
            return true
        }
        if !old.isNonisolated, new.isNonisolated {
            return true
        }
        if old.isSendable, !new.isSendable {
            return true
        }
        if !old.isPreconcurrency, new.isPreconcurrency {
            return true
        }
        if old.isAsync, !new.isAsync {
            return true
        }
        return false
    }

    private static func consolidated(
        _ changes: [SDKSymbolChange]
    ) -> [SDKSymbolChange] {
        var remaining = changes
        if let concurrency = changes.first(
            where: { $0.kind == .concurrencyChanged }
        ), let candidate = concurrency.candidate {
            let parameterChange = changes.first {
                $0.kind == .parameterTypesChanged
            }
            let signatureChange = changes.first {
                $0.kind == .signatureChanged
            }
            let parameterIsConcurrencyOnly = parameterChange.map {
                typesDifferOnlyByConcurrency(
                    $0.baseline.parameters.map(\.type),
                    candidate.parameters.map(\.type)
                )
            } ?? false
            let signatureIsConcurrencyOnly = signatureChange.map {
                normalizedConcurrencyText($0.baseline.signature)
                    == normalizedConcurrencyText(candidate.signature)
            } ?? false
            let suppressedKinds = Set(
                [
                    parameterIsConcurrencyOnly ? SDKChangeKind.parameterTypesChanged : nil,
                    signatureIsConcurrencyOnly ? SDKChangeKind.signatureChanged : nil,
                ].compactMap { $0 }
            )
            remaining = changes.filter { !suppressedKinds.contains($0.kind) }
        }
        return consolidateSignatureFacets(remaining)
    }

    private static func consolidateSignatureFacets(
        _ changes: [SDKSymbolChange]
    ) -> [SDKSymbolChange] {
        let signatureKinds: Set<SDKChangeKind> = [
            .signatureChanged,
            .parameterLabelsChanged,
            .parameterTypesChanged,
            .returnTypeChanged,
            .concurrencyChanged,
        ]
        let facets = changes.filter { signatureKinds.contains($0.kind) }
        guard facets.count > 1, let first = facets.first else {
            return changes
        }
        let primary = facets.first { $0.kind == .parameterLabelsChanged }
            ?? facets.first { $0.kind == .parameterTypesChanged }
            ?? facets.first { $0.kind == .returnTypeChanged }
            ?? facets.first { $0.kind == .concurrencyChanged }
            ?? facets.first { $0.kind == .signatureChanged }
            ?? first
        let combined = SDKSymbolChange(
            kind: primary.kind,
            baseline: primary.baseline,
            candidate: primary.candidate,
            matchConfidence: facets.map(\.matchConfidence).min {
                $0.rank < $1.rank
            } ?? primary.matchConfidence,
            observedChange: facets
                .sorted { $0.kind.rawValue < $1.kind.rawValue }
                .map(\.observedChange)
                .joined(separator: " ")
        )
        return changes.filter { !signatureKinds.contains($0.kind) } + [combined]
    }

    private static func typesDifferOnlyByConcurrency(
        _ old: [String?],
        _ new: [String?]
    ) -> Bool {
        guard old != new, old.count == new.count else { return false }
        return zip(old, new).allSatisfy {
            normalizedConcurrencyText($0.0) == normalizedConcurrencyText($0.1)
        }
    }

    private static func normalizedConcurrencyText(_ value: String?) -> String {
        (value ?? "")
            .replacingOccurrences(
                of: #"@(Sendable|escaping|autoclosure|isolated\([^)]*\))\s*"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"@_[A-Za-z0-9_]+(?:\([^)]*\))?\s*"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
    }

    private static func minimum(_ lhs: Confidence, _ rhs: Confidence) -> Confidence {
        lhs.rank <= rhs.rank ? lhs : rhs
    }

    private static func sameSourceExpression(
        _ lhs: SourceLocation?,
        _ rhs: SourceLocation
    ) -> Bool {
        guard let lhs else { return false }
        return sameSourceExpression(lhs, rhs)
    }

    private static func sameSourceExpression(
        _ lhs: SourceLocation,
        _ rhs: SourceLocation
    ) -> Bool {
        guard URL(fileURLWithPath: lhs.path).standardizedFileURL.path
                == URL(fileURLWithPath: rhs.path).standardizedFileURL.path,
              lhs.line == rhs.line
        else {
            return false
        }
        switch (lhs.column, rhs.column) {
        case let (left?, right?):
            return abs(left - right) <= 2
        case (nil, nil):
            return true
        default:
            return false
        }
    }
}
