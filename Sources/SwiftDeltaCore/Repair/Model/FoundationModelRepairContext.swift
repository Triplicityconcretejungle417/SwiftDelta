//===--- FoundationModelRepairContext.swift - SwiftDelta ------------------------------------------===//
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

enum FoundationModelRepairContextBuilder {
    static func build(
        sdkOutput: SDKAnalysisOutput,
        deterministicRepairs: [ProposedRepair],
        compilerFixIts: [StructuredDiagnosticFixIt] = [],
        projectRoot: URL
    ) -> [RepairContext] {
        buildWithFailures(
            sdkOutput: sdkOutput,
            deterministicRepairs: deterministicRepairs,
            compilerFixIts: compilerFixIts,
            projectRoot: projectRoot
        ).contexts
    }

    static func buildWithFailures(
        sdkOutput: SDKAnalysisOutput,
        findings: [Finding]? = nil,
        deterministicRepairs: [ProposedRepair],
        compilerFixIts: [StructuredDiagnosticFixIt],
        projectRoot: URL,
        selectedFindingIdentifiers: Set<String> = []
    ) -> (
        contexts: [RepairContext],
        failures: [AnalysisFailure],
        findingsConsidered: Int,
        skipped: Int,
        skipReasons: [String: String]
    ) {
        let baselineSymbols = sdkOutput.baselineSnapshots.flatMap(\.symbols)
        let candidateSymbols = sdkOutput.candidateSnapshots.flatMap(\.symbols)
        let root = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        var contexts: [RepairContext] = []
        var failures: [AnalysisFailure] = []
        var findingsConsidered = 0
        var skipped = 0
        var skipReasons: [String: String] = [:]

        func recordSkip(_ finding: Finding, _ reason: String) {
            skipped += 1
            skipReasons[finding.stableKey] = reason
        }

        let analysisFindings = (findings ?? sdkOutput.findings).sorted(by: {
            $0.stableKey < $1.stableKey
        })
        for finding in analysisFindings {
            guard !hasSafeDeterministicRepair(
                for: finding,
                repairs: deterministicRepairs,
                root: root
            ) else {
                continue
            }
            findingsConsidered += 1
            guard finding.origin == .sdk else {
                recordSkip(
                    finding,
                    "Foundation Models requires an SDK-derived finding with "
                        + "an exact project source reference."
                )
                continue
            }
            guard let evidence = finding.sdkEvidence else {
                recordSkip(finding, "The finding has no SDK evidence.")
                continue
            }
            guard evidence.resolutionMethod != .uncertainText else {
                recordSkip(
                    finding,
                    "The SDK reference is an unresolved textual match."
                )
                continue
            }
            guard let location = finding.location,
                  sameSource(
                    evidence.sourceLocation,
                    location,
                    root: root
                  )
            else {
                recordSkip(
                    finding,
                    "The SDK evidence does not have one exact matching project "
                        + "source location."
                )
                continue
            }
            let baseline: SDKSymbol?
            if let identifier = evidence.preciseIdentifier,
               !identifier.isEmpty
            {
                baseline = uniqueSymbol(
                    identifier: identifier,
                    module: evidence.moduleName,
                    symbols: baselineSymbols
                )
            } else {
                baseline = uniqueQualifiedSymbol(
                    name: evidence.fullyQualifiedName,
                    declaration: evidence.oldDeclaration,
                    module: evidence.moduleName,
                    symbols: baselineSymbols
                )
            }
            guard let baseline else {
                recordSkip(
                    finding,
                    "The baseline SDK symbol cannot be matched uniquely by "
                        + "stable identity or qualified declaration."
                )
                continue
            }
            guard let candidate = replacementSymbol(
                for: baseline,
                evidence: evidence,
                symbols: candidateSymbols
            ) else {
                recordSkip(
                    finding,
                    "The candidate SDK evidence does not identify one "
                        + "unambiguous current or replacement symbol."
                )
                continue
            }
            guard let baselineSDKDeclaration =
                    evidence.oldDeclaration ?? baseline.declaration,
                  let candidateSDKDeclaration =
                    candidate.declaration ?? evidence.newDeclaration,
                  hasMeaningfulSDKDifference(
                    finding: finding,
                    evidence: evidence,
                    baselineDeclaration: baselineSDKDeclaration,
                    candidateDeclaration: candidateSDKDeclaration
                  )
            else {
                recordSkip(
                    finding,
                    "The SDK evidence has no meaningful old/new declaration "
                        + "difference."
                )
                continue
            }
            let baselineIdentifier = evidence.preciseIdentifier
                ?? baseline.preciseIdentifier
                ?? baseline.id
            let candidateIdentifier = candidate.preciseIdentifier
                ?? candidate.id
            guard !baselineIdentifier.isEmpty,
                  !candidateIdentifier.isEmpty
            else {
                recordSkip(
                    finding,
                    "The SDK symbols have no stable snapshot identity."
                )
                continue
            }

            do {
                let file = sourceURL(location.path, root: root)
                let document = try RepairSourceDocument(root: root, file: file)
                guard document.language == .swift,
                      let line = location.line,
                      let lineRange = lineRange(line, in: document)
                else {
                    recordSkip(
                        finding,
                        "The exact source location is unreadable, unsupported, "
                            + "or outside Swift source."
                    )
                    continue
                }
                let focusedRange = tokenRange(
                    at: location,
                    lineRange: lineRange,
                    document: document
                ) ?? lineRange
                do {
                    let relevantDiagnostics = uniqueDiagnostics(
                        sdkOutput.candidateDiagnostics.filter {
                            sameSource($0.location, location, root: root)
                                && targetsMatch($0.target, finding.target)
                        }
                    )
                    let diagnostic = relevantDiagnostics.count == 1
                        ? relevantDiagnostics[0] : nil
                    if diagnostic == nil,
                       finding.severity == .notice,
                       isInformationalMetadataChange(evidence.changeKind)
                    {
                        recordSkip(
                            finding,
                            "No source change is required by current compiler "
                                + "evidence; this SDK metadata change remains "
                                + "informational for repair planning."
                        )
                        continue
                    }
                    let diagnosticIdentifier = diagnostic.map {
                        $0.diagnosticID
                            ?? RepairFingerprint.identifier([
                                "compiler-diagnostic",
                                $0.deduplicationKey,
                            ])
                    }
                    let sourcePath = normalizedPath(
                        location.path,
                        root: root
                    )
                    let matchingContexts =
                        sdkOutput.candidateBuildContexts.filter {
                            ($0.target == finding.target
                                || finding.target == nil)
                                && $0.sdkIdentifier
                                    == evidence.candidate.sdkIdentifier
                                && $0.analysisSourceFiles.contains {
                                    normalizedPath($0, root: root)
                                        == sourcePath
                                }
                        }
                    let authoritative = matchingContexts.filter(
                        \.isAuthoritative
                    )
                    let targetContexts = authoritative.isEmpty
                        ? matchingContexts : authoritative
                    let uniqueTargetContexts = Dictionary(
                        targetContexts.map { ($0.contextIdentity, $0) },
                        uniquingKeysWith: { first, _ in first }
                    ).values.sorted {
                        $0.contextIdentity < $1.contextIdentity
                    }
                    guard uniqueTargetContexts.count == 1,
                          let targetContext = uniqueTargetContexts.first
                    else {
                        recordSkip(
                            finding,
                            targetContexts.isEmpty
                                ? "No selected target and SDK build context "
                                    + "contains this source file."
                                : "More than one selected target build context "
                                    + "contains this source reference."
                        )
                        continue
                    }
                    let declarationRange = enclosingDeclarationRange(
                        document: document,
                        targetOffset: focusedRange.start.utf8Offset
                    )
                    let allowedRange =
                        declarationRange.map { range in
                            min(range.count, maximumEditableDeclarationBytes)
                                == range.count
                                ? RepairSourceRange(
                                    start: sourcePosition(
                                        range.lowerBound,
                                        in: document.data
                                    ),
                                    end: sourcePosition(
                                        range.upperBound,
                                        in: document.data
                                    )
                                )
                                : lineRange
                        } ?? lineRange
                    let sourceFragment = try document.text(in: allowedRange)
                    let enclosing = declarationRange.flatMap {
                        String(
                            data: document.data.subdata(in: $0),
                            encoding: .utf8
                        )
                    } ?? sourceFragment
                    guard !sourceFragment.isEmpty,
                          !enclosing.trimmingCharacters(
                            in: .whitespacesAndNewlines
                          ).isEmpty
                    else {
                        recordSkip(
                            finding,
                            "SwiftSyntax could not produce a nonempty enclosing "
                                + "source declaration."
                        )
                        continue
                    }
                    let fixItEvidence = compilerFixIts.filter {
                        normalizedPath($0.filePath, root: root)
                            == normalizedPath(location.path, root: root)
                            && rangesTouch($0.sourceRange, focusedRange)
                            && compilerContextsMatch(
                                $0.compilerContext,
                                targetContext: targetContext
                            )
                    }.map {
                        "compiler fix-it \($0.sourceRange.start.utf8Offset)-"
                            + "\($0.sourceRange.end.utf8Offset): \($0.replacementText)"
                    }.sorted()
                    let deterministicCandidates = deterministicRepairs.filter {
                        $0.relatedFindingIdentifier == finding.findingID
                            && normalizedPath($0.filePath, root: root)
                                == normalizedPath(location.path, root: root)
                    }.map {
                        "\($0.evidenceSource.rawValue) \($0.safety.rawValue) "
                            + "\($0.sourceRange.start.utf8Offset)-"
                            + "\($0.sourceRange.end.utf8Offset): "
                            + "\($0.originalText) -> \($0.replacementText)"
                    }.sorted()
                    contexts.append(
                        RepairContext(
                            relatedFindingIdentifier: finding.findingID,
                            findingStableKey: finding.stableKey,
                            findingSeverity: finding.severity,
                            userSelected:
                                selectedFindingIdentifiers.contains(
                                    finding.findingID
                                )
                                || selectedFindingIdentifiers.contains(
                                    finding.stableKey
                                ),
                            evidenceLevel: diagnostic == nil
                                ? .sdkRisk : .diagnosticBacked,
                            diagnostic: diagnostic,
                            diagnosticIdentifier: diagnosticIdentifier,
                            filePath: document.relativePath,
                            language: document.language,
                            sourceFragment: sourceFragment,
                            enclosingDeclaration: enclosing,
                            allowedEditingRange: allowedRange,
                            sourceFingerprint: document.fingerprint,
                            resolvedSymbolIdentity: baselineIdentifier,
                            candidateSymbolIdentity: candidateIdentifier,
                            baselineSDKDeclaration: baselineSDKDeclaration,
                            candidateSDKDeclaration: candidateSDKDeclaration,
                            sdkDifferences: sdkDifferenceEvidence(evidence)
                                + relatedCandidateDeclarations(
                                    for: candidate,
                                    baseline: baseline,
                                    evidence: evidence,
                                    symbols: candidateSymbols
                                )
                                + relatedRenameEvidence(
                                    findings: analysisFindings,
                                    excluding: finding,
                                    sourcePath: location.path,
                                    allowedRange: allowedRange,
                                    module: evidence.moduleName,
                                    baselineSymbols: baselineSymbols,
                                    candidateSymbols: candidateSymbols,
                                    root: root
                                ),
                            compilerFixItEvidence: fixItEvidence,
                            deterministicRepairCandidates:
                                deterministicCandidates,
                            restrictions: restrictions
                                + exactMigrationRestrictions(
                                    baseline: baseline,
                                    candidate: candidate,
                                    evidence: evidence
                                ),
                            toolchains: RepairToolchainEvidence(
                                baseline: evidence.baseline,
                                candidate: evidence.candidate
                            ),
                            symbols: RepairSymbolEvidence(
                                baselinePreciseIdentifier: baselineIdentifier,
                                candidatePreciseIdentifier: candidateIdentifier,
                                moduleName: evidence.moduleName,
                                baselineDeclaration: baseline.declaration,
                                candidateDeclaration: candidate.declaration
                            ),
                            compilerContext: RepairCompilerContextEvidence(
                                compilerPath: URL(
                                    fileURLWithPath:
                                        evidence.candidate.developerDirectory
                                )
                                .appendingPathComponent(
                                    "Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
                                ).path,
                                target: targetContext.target,
                                moduleName: targetContext.moduleName,
                                sdkIdentifier: targetContext.sdkIdentifier,
                                sdkPath: targetContext.sdkPath,
                                destination: targetContext.destination,
                                diagnosticIdentity: diagnosticIdentifier
                                    ?? RepairFingerprint.identifier([
                                        "sdk-finding",
                                        finding.stableKey,
                                        baselineIdentifier,
                                        candidateIdentifier,
                                    ]),
                                evidenceArtifact: diagnostic == nil
                                    ? "targetAwareSDKReference"
                                    : "targetAwareCompilerDiagnostic",
                                isTargetAware: targetContext.isAuthoritative
                            )
                        )
                    )
                }
            } catch let error as RepairError {
                recordSkip(
                    finding,
                    "The source could not be prepared safely: "
                        + error.localizedDescription
                )
                if case .protectedPath = error {
                    continue
                }
                failures.append(
                    AnalysisFailure(
                        kind: .fileRead,
                        message:
                            "Foundation Models repair context could not read "
                            + "\(location.path): \(error.localizedDescription)",
                        location: location
                    )
                )
            } catch {
                recordSkip(
                    finding,
                    "The source context could not be prepared: "
                        + error.localizedDescription
                )
                failures.append(
                    AnalysisFailure(
                        kind: .fileRead,
                        message:
                            "Foundation Models repair context could not read "
                            + "\(location.path): \(error.localizedDescription)",
                        location: location
                    )
                )
            }
        }

        let values = Array(Set(contexts)).sorted {
            (
                $0.filePath,
                $0.allowedEditingRange.start.utf8Offset,
                $0.diagnosticIdentifier ?? "",
                $0.relatedFindingIdentifier
            ) < (
                $1.filePath,
                $1.allowedEditingRange.start.utf8Offset,
                $1.diagnosticIdentifier ?? "",
                $1.relatedFindingIdentifier
            )
        }
        return (
            values,
            failures,
            findingsConsidered,
            skipped,
            skipReasons
        )
    }

    private static let restrictions = [
        "Use at most eight exact anchored edits inside the allowed range.",
        "Use only candidate SDK symbols and declarations supplied in this context.",
        "Do not add dependencies, build settings, or project changes.",
        "Do not invent APIs, signatures, fallback behavior, ownership, or error handling.",
        "Coordinated syntax changes remain review-required until candidate-Xcode verification succeeds.",
        "Return notRepairable if the existing evidence does not prove the edit.",
    ]

    private static let maximumEditableDeclarationBytes = 12_000

    private static func exactMigrationRestrictions(
        baseline: SDKSymbol,
        candidate: SDKSymbol,
        evidence: SDKFindingEvidence
    ) -> [String] {
        guard evidence.changeKind == .renamed,
              let destination = SDKRenameResolver.destination(for: baseline)
                ?? evidence.newAvailability.compactMap(\.renamed).first
                ?? evidence.oldAvailability.compactMap(\.renamed).first,
              !baseline.baseName.isEmpty,
              !destination.isEmpty
        else { return [] }
        var values = [
            "The exact source token \(baseline.baseName) is the migration target. "
                + "Any concrete revised source must remove that token at the "
                + "supplied occurrence and access the SDK rename destination "
                + "\(destination). Return notRepairable instead of preserving "
                + "the old token or merely reformatting the declaration.",
        ]
        if let oldType = declaredValueType(
            baseline.declaration ?? evidence.oldDeclaration
        ),
        let newType = declaredValueType(
            candidate.declaration ?? evidence.newDeclaration
        ),
        oldType != newType
        {
            values.append(
                "The renamed value type changed from \(oldType) to \(newType). "
                    + "Do not assign or return the old value type at the new "
                    + "destination. Use only the related candidate value or "
                    + "member declarations supplied by the SDK evidence."
            )
        }
        return values
    }

    private static func declaredValueType(_ declaration: String?) -> String? {
        guard let declaration,
              let colon = declaration.firstIndex(of: ":")
        else { return nil }
        let suffix = declaration[declaration.index(after: colon)...]
        let end = suffix.firstIndex(of: "{") ?? suffix.endIndex
        let value = suffix[..<end].trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return value.isEmpty ? nil : value
    }

    private static func isInformationalMetadataChange(
        _ kind: SDKChangeKind
    ) -> Bool {
        switch kind {
        case .newlyDeprecated, .availabilityChanged,
             .concurrencyChanged, .propertyAccessChanged,
             .protocolRequirementChanged, .inheritanceChanged,
             .conformanceChanged:
            return true
        case .removed, .newlyUnavailable, .renamed,
             .signatureChanged, .parameterLabelsChanged,
             .parameterTypesChanged, .returnTypeChanged:
            return false
        }
    }

    private static func uniqueSymbol(
        identifier: String,
        module: String,
        symbols: [SDKSymbol]
    ) -> SDKSymbol? {
        let matches = symbols.filter {
            $0.moduleName == module && $0.preciseIdentifier == identifier
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func uniqueCandidateSymbol(
        declaration: String,
        name: String,
        module: String,
        symbols: [SDKSymbol]
    ) -> SDKSymbol? {
        let matches = symbols.filter {
            $0.moduleName == module
                && $0.declaration == declaration
        }
        if matches.count == 1 {
            return matches[0]
        }
        let named = matches.filter {
            $0.fullyQualifiedName == name
        }
        return named.count == 1 ? named[0] : nil
    }

    private static func replacementSymbol(
        for baseline: SDKSymbol,
        evidence: SDKFindingEvidence,
        symbols: [SDKSymbol]
    ) -> SDKSymbol? {
        if let destination = SDKRenameResolver.destination(for: baseline)
            ?? evidence.newAvailability.compactMap(\.renamed).first
            ?? evidence.oldAvailability.compactMap(\.renamed).first,
           let replacement = SDKRenameResolver.uniqueDestination(
                for: baseline,
                destination: destination,
                in: symbols
           )
        {
            return replacement
        }
        guard let declaration = evidence.newDeclaration else {
            return nil
        }
        return uniqueCandidateSymbol(
            declaration: declaration,
            name: evidence.fullyQualifiedName,
            module: evidence.moduleName,
            symbols: symbols
        )
    }

    private static func uniqueQualifiedSymbol(
        name: String,
        declaration: String?,
        module: String,
        symbols: [SDKSymbol]
    ) -> SDKSymbol? {
        let matches = symbols.filter {
            $0.moduleName == module
                && $0.fullyQualifiedName == name
                && (declaration == nil || $0.declaration == declaration)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func hasMeaningfulSDKDifference(
        finding: Finding,
        evidence: SDKFindingEvidence,
        baselineDeclaration: String,
        candidateDeclaration: String
    ) -> Bool {
        if baselineDeclaration.trimmingCharacters(in: .whitespacesAndNewlines)
            != candidateDeclaration.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        {
            return true
        }
        if evidence.oldAvailability != evidence.newAvailability {
            return true
        }
        if evidence.migrationMessage?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty == false {
            return true
        }
        switch evidence.changeKind {
        case .renamed, .newlyDeprecated, .newlyUnavailable,
             .availabilityChanged, .concurrencyChanged,
             .parameterLabelsChanged, .parameterTypesChanged,
             .returnTypeChanged, .signatureChanged,
             .propertyAccessChanged, .protocolRequirementChanged,
             .inheritanceChanged, .conformanceChanged, .removed:
            return !evidence.observedChange.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty && finding.confidence != .low
        }
    }

    private static func sdkDifferenceEvidence(
        _ evidence: SDKFindingEvidence
    ) -> [String] {
        var values = [evidence.observedChange]
        if let message = evidence.migrationMessage,
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            values.append("SDK migration message: \(message)")
        }
        if evidence.oldAvailability != evidence.newAvailability {
            values.append(
                "Baseline availability: "
                    + availabilityDescription(evidence.oldAvailability)
            )
            values.append(
                "Candidate availability: "
                    + availabilityDescription(evidence.newAvailability)
            )
        }
        return values
    }

    private static func relatedCandidateDeclarations(
        for symbol: SDKSymbol,
        baseline: SDKSymbol,
        evidence: SDKFindingEvidence,
        symbols: [SDKSymbol]
    ) -> [String] {
        guard let declaration = symbol.declaration else { return [] }
        var values: [String] = []

        // Importer rename metadata can name a path through an intermediate
        // property (for example owner.configuration.member) while the symbol
        // graph identifies only the final member. Supply the declaration for
        // each uniquely resolved path component so a structural migration does
        // not have to invent how the destination is reached.
        if let destination = SDKRenameResolver.destination(for: baseline)
            ?? evidence.newAvailability.compactMap(\.renamed).first
            ?? evidence.oldAvailability.compactMap(\.renamed).first
        {
            let destinationHead = destination.split(
                separator: "(",
                maxSplits: 1
            ).first.map(String.init) ?? destination
            var components = destinationHead.split(separator: ".").map(String.init)
            if components.first == baseline.moduleName {
                components.removeFirst()
            }
            let baselineOwner = baseline.fullyQualifiedName
                .split(separator: ".")
                .dropLast()
                .joined(separator: ".")
            for component in components.dropLast() {
                let expectedName = "\(baselineOwner).\(component)"
                let matches = symbols.filter {
                    $0.moduleName == baseline.moduleName
                        && $0.fullyQualifiedName == expectedName
                        && $0.preciseIdentifier?.isEmpty == false
                        && $0.declaration?.isEmpty == false
                }
                if matches.count == 1, let match = matches.first,
                   let matchDeclaration = match.declaration
                {
                    values.append(
                        "Candidate destination path declaration: "
                            + "\(match.fullyQualifiedName) — \(matchDeclaration)"
                    )
                }
            }
        }

        guard let expression = try? NSRegularExpression(
                pattern: #"\b[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)+\b"#
              )
        else { return values }
        let range = NSRange(declaration.startIndex..., in: declaration)
        let typePaths = Set(expression.matches(
            in: declaration,
            range: range
        ).compactMap { match in
            Range(match.range, in: declaration).map {
                String(declaration[$0])
            }
        })
        guard !typePaths.isEmpty else { return values }
        let related = symbols.compactMap { candidate -> String? in
            guard candidate.moduleName == symbol.moduleName,
                  candidate.preciseIdentifier?.isEmpty == false,
                  candidate.preciseIdentifier != symbol.preciseIdentifier,
                  let memberDeclaration = candidate.declaration,
                  typePaths.contains(where: {
                    candidate.fullyQualifiedName.hasPrefix(
                        "\(symbol.moduleName).\($0)."
                    )
                  }),
                  memberDeclaration.hasPrefix("static ")
                    || memberDeclaration.hasPrefix("case ")
            else { return nil }
            return "Related candidate SDK declaration: "
                + "\(candidate.fullyQualifiedName) — \(memberDeclaration)"
        }.sorted()
        values.append(contentsOf: related.prefix(12))
        return Array(Set(values)).sorted()
    }

    private static func relatedRenameEvidence(
        findings: [Finding],
        excluding finding: Finding,
        sourcePath: String,
        allowedRange: RepairSourceRange,
        module: String,
        baselineSymbols: [SDKSymbol],
        candidateSymbols: [SDKSymbol],
        root: URL
    ) -> [String] {
        var values: [String] = []
        for related in findings where related.findingID != finding.findingID {
            guard related.origin == .sdk,
                  let location = related.location,
                  normalizedPath(location.path, root: root)
                    == normalizedPath(sourcePath, root: root),
                  let line = location.line,
                  line >= allowedRange.start.line,
                  line <= allowedRange.end.line,
                  let evidence = related.sdkEvidence,
                  evidence.moduleName == module,
                  evidence.changeKind == .renamed,
                  evidence.resolutionMethod != .uncertainText
            else { continue }
            let baseline: SDKSymbol?
            if let identifier = evidence.preciseIdentifier,
               !identifier.isEmpty
            {
                baseline = uniqueSymbol(
                    identifier: identifier,
                    module: module,
                    symbols: baselineSymbols
                )
            } else {
                baseline = uniqueQualifiedSymbol(
                    name: evidence.fullyQualifiedName,
                    declaration: evidence.oldDeclaration,
                    module: module,
                    symbols: baselineSymbols
                )
            }
            guard let baseline,
                  let candidate = replacementSymbol(
                    for: baseline,
                    evidence: evidence,
                    symbols: candidateSymbols
                  ),
                  let destination = SDKRenameResolver.destination(for: baseline)
                    ?? evidence.newAvailability.compactMap(\.renamed).first
                    ?? evidence.oldAvailability.compactMap(\.renamed).first,
                  let oldDeclaration = evidence.oldDeclaration
                    ?? baseline.declaration,
                  let newDeclaration = candidate.declaration
                    ?? evidence.newDeclaration
            else { continue }
            values.append(
                "Related exact SDK rename in the same source declaration: "
                    + "\(evidence.fullyQualifiedName) — \(oldDeclaration) "
                    + "renamed to \(destination); candidate declaration: "
                    + newDeclaration
            )
            values.append(contentsOf: relatedCandidateDeclarations(
                for: candidate,
                baseline: baseline,
                evidence: evidence,
                symbols: candidateSymbols
            ))
        }
        return Array(Set(values)).sorted()
    }

    private static func availabilityDescription(
        _ values: [SDKAvailability]
    ) -> String {
        values.isEmpty
            ? "none"
            : values.map(\.description).joined(separator: " | ")
    }

    private static func hasSafeDeterministicRepair(
        for finding: Finding,
        repairs: [ProposedRepair],
        root: URL
    ) -> Bool {
        guard let location = finding.location else { return false }
        let source = normalizedPath(location.path, root: root)
        return repairs.contains { repair in
            guard repair.safety == .safe,
                  repair.relatedFindingIdentifier == finding.findingID,
                  normalizedPath(repair.filePath, root: root) == source
            else {
                return false
            }
            guard let line = location.line else { return true }
            return repair.sourceRange.start.line == line
        }
    }

    private static func uniqueDiagnostics(
        _ diagnostics: [CompilerDiagnostic]
    ) -> [CompilerDiagnostic] {
        var seen = Set<String>()
        return diagnostics.filter {
            seen.insert($0.deduplicationKey).inserted
        }
    }

    private static func sourceURL(_ path: String, root: URL) -> URL {
        NSString(string: path).isAbsolutePath
            ? URL(fileURLWithPath: path)
            : root.appendingPathComponent(path)
    }

    private static func sameSource(
        _ diagnostic: SourceLocation?,
        _ finding: SourceLocation,
        root: URL
    ) -> Bool {
        guard let diagnostic,
              diagnostic.line == finding.line,
              diagnostic.column == nil
                || finding.column == nil
                || diagnostic.column == finding.column
        else {
            return false
        }
        return normalizedPath(diagnostic.path, root: root)
            == normalizedPath(finding.path, root: root)
    }

    private static func targetsMatch(
        _ diagnosticTarget: String?,
        _ findingTarget: String?
    ) -> Bool {
        diagnosticTarget == nil
            || findingTarget == nil
            || diagnosticTarget == findingTarget
    }

    private static func compilerContextsMatch(
        _ evidence: RepairCompilerContextEvidence?,
        targetContext: TargetBuildContext
    ) -> Bool {
        guard let evidence else { return true }
        return (evidence.target == nil || evidence.target == targetContext.target)
            && (evidence.moduleName == nil
                || evidence.moduleName == targetContext.moduleName)
            && evidence.sdkIdentifier == targetContext.sdkIdentifier
    }

    private static func rangesTouch(
        _ left: RepairSourceRange,
        _ right: RepairSourceRange
    ) -> Bool {
        left.start.utf8Offset <= right.end.utf8Offset
            && right.start.utf8Offset <= left.end.utf8Offset
    }

    private static func tokenRange(
        at location: SourceLocation,
        lineRange: RepairSourceRange,
        document: RepairSourceDocument
    ) -> RepairSourceRange? {
        guard let column = location.column, column > 0 else {
            return nil
        }
        let lineData = document.data.subdata(
            in: lineRange.start.utf8Offset..<lineRange.end.utf8Offset
        )
        guard let line = String(data: lineData, encoding: .utf8) else {
            return nil
        }
        let characterIndex = line.index(
            line.startIndex,
            offsetBy: min(column - 1, line.count)
        )
        let target = lineRange.start.utf8Offset
            + line[..<characterIndex].utf8.count
        let tree = Parser.parse(source: document.text)
        for token in tree.tokens(viewMode: .sourceAccurate) {
            let start = token.positionAfterSkippingLeadingTrivia.utf8Offset
            let end = token.endPositionBeforeTrailingTrivia.utf8Offset
            if start <= target, target <= end, start < end {
                return RepairSourceRange(
                    start: sourcePosition(start, in: document.data),
                    end: sourcePosition(end, in: document.data)
                )
            }
        }
        return nil
    }

    private static func normalizedPath(_ path: String, root: URL) -> String {
        let url = NSString(string: path).isAbsolutePath
            ? URL(fileURLWithPath: path)
            : root.appendingPathComponent(path)
        return url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func lineRange(
        _ requestedLine: Int,
        in document: RepairSourceDocument
    ) -> RepairSourceRange? {
        guard requestedLine > 0 else {
            return nil
        }
        let bytes = Array(document.data)
        var line = 1
        var start = 0
        while line < requestedLine, start < bytes.count {
            guard let newline = bytes[start...].firstIndex(of: 0x0A) else {
                return nil
            }
            start = newline + 1
            line += 1
        }
        guard line == requestedLine, start <= bytes.count else {
            return nil
        }
        var end = bytes[start...].firstIndex(of: 0x0A) ?? bytes.count
        if end > start, bytes[end - 1] == 0x0D {
            end -= 1
        }
        return RepairSourceRange(
            start: sourcePosition(start, in: document.data),
            end: sourcePosition(end, in: document.data)
        )
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

    private static func enclosingDeclarationRange(
        document: RepairSourceDocument,
        targetOffset: Int
    ) -> Range<Int>? {
        let tree = Parser.parse(source: document.text)
        let visitor = FoundationModelEnclosingDeclarationVisitor(
            targetOffset: targetOffset
        )
        visitor.walk(tree)
        guard let range = visitor.bestRange,
              range.lowerBound >= 0,
              range.upperBound <= document.data.count,
              range.lowerBound < range.upperBound
        else {
            return nil
        }
        return range
    }
}

private final class FoundationModelEnclosingDeclarationVisitor: SyntaxVisitor {
    let targetOffset: Int
    private(set) var bestRange: Range<Int>?

    init(targetOffset: Int) {
        self.targetOffset = targetOffset
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        consider(node)
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        consider(node)
    }

    override func visit(_ node: DeinitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        consider(node)
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        consider(node)
    }

    override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind {
        consider(node)
    }

    override func visit(_ node: AccessorDeclSyntax) -> SyntaxVisitorContinueKind {
        consider(node)
    }

    override func visit(_ node: MacroDeclSyntax) -> SyntaxVisitorContinueKind {
        consider(node)
    }

    private func consider(_ node: some SyntaxProtocol) -> SyntaxVisitorContinueKind {
        let range = (
            node.positionAfterSkippingLeadingTrivia.utf8Offset
        )..<(node.endPositionBeforeTrailingTrivia.utf8Offset)
        guard range.contains(targetOffset) else {
            return .skipChildren
        }
        if range.count < (bestRange?.count ?? .max) {
            bestRange = range
        }
        return .visitChildren
    }
}
