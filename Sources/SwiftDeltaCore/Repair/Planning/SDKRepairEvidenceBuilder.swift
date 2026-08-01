//===--- SDKRepairEvidenceBuilder.swift - SwiftDelta ------------------------------------------===//
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

public enum SDKRepairEvidenceBuilder {
    public static func build(
        findings: [Finding],
        baselineSnapshots: [SDKSnapshot],
        candidateSnapshots: [SDKSnapshot],
        projectRoot: URL,
        targetBuildContexts: [TargetBuildContext] = []
    ) -> ([ProposedRepair], [AnalysisFailure]) {
        let baselineSymbols = baselineSnapshots.flatMap(\.symbols)
        let candidateSymbols = candidateSnapshots.flatMap(\.symbols)
        var repairs: [ProposedRepair] = []
        var failures: [AnalysisFailure] = []

        for finding in findings where finding.origin == .sdk {
            // Deterministic edits require identities; weaker evidence remains
            // reviewable.
            guard let evidence = finding.sdkEvidence,
                  evidence.resolutionMethod == .compilerUSR,
                  finding.confidence == .high,
                  let oldIdentifier = evidence.preciseIdentifier,
                  !oldIdentifier.isEmpty,
                  let oldSymbol = uniqueSymbol(
                      preciseIdentifier: oldIdentifier,
                      module: evidence.moduleName,
                      in: baselineSymbols
                  )
            else {
                continue
            }
            do {
                switch evidence.changeKind {
                case .renamed:
                    if let repair = try renameRepair(
                        finding: finding,
                        evidence: evidence,
                        oldSymbol: oldSymbol,
                        candidateSymbols: candidateSymbols,
                        projectRoot: projectRoot,
                        targetBuildContexts: targetBuildContexts,
                        requireCompleteEvidence: true
                    ) {
                        repairs.append(repair)
                    }
                case .newlyDeprecated, .newlyUnavailable, .removed:
                    if !hasExplicitRenameFinding(
                        for: finding,
                        evidence: evidence,
                        in: findings
                    ), let repair = try renameRepair(
                        finding: finding,
                        evidence: evidence,
                        oldSymbol: oldSymbol,
                        candidateSymbols: candidateSymbols,
                        projectRoot: projectRoot,
                        targetBuildContexts: targetBuildContexts,
                        requireCompleteEvidence: false
                    ) {
                        repairs.append(repair)
                    }
                case .parameterLabelsChanged, .signatureChanged:
                    if let repair = try parameterLabelRepair(
                        finding: finding,
                        evidence: evidence,
                        oldSymbol: oldSymbol,
                        candidateSymbols: candidateSymbols,
                        projectRoot: projectRoot
                    ) {
                        repairs.append(repair)
                    }
                default:
                    continue
                }
            } catch {
                failures.append(
                    AnalysisFailure(
                        kind: .parse,
                        message: "Could not plan SDK-derived repair: \(error.localizedDescription)",
                        location: finding.location
                    )
                )
            }
        }
        return (repairs, failures)
    }

    private static func hasExplicitRenameFinding(
        for finding: Finding,
        evidence: SDKFindingEvidence,
        in findings: [Finding]
    ) -> Bool {
        findings.contains { candidate in
            guard candidate.findingID != finding.findingID,
                  let other = candidate.sdkEvidence,
                  other.changeKind == .renamed,
                  other.moduleName == evidence.moduleName,
                  other.preciseIdentifier == evidence.preciseIdentifier,
                  candidate.location?.line == finding.location?.line,
                  candidate.location?.column == finding.location?.column
            else { return false }
            return candidate.location?.path == finding.location?.path
                || other.sourceLocation.path == evidence.sourceLocation.path
        }
    }

    private static func renameRepair(
        finding: Finding,
        evidence: SDKFindingEvidence,
        oldSymbol: SDKSymbol,
        candidateSymbols: [SDKSymbol],
        projectRoot: URL,
        targetBuildContexts: [TargetBuildContext],
        requireCompleteEvidence: Bool
    ) throws -> ProposedRepair? {
        guard let destination = renameDestination(
            oldSymbol,
            evidence: evidence
        ) else {
            if requireCompleteEvidence {
                throw SDKRenameRepairBlocker(
                    "the SDK rename metadata has no destination"
                )
            }
            return nil
        }
        guard let newSymbol = SDKRenameResolver.uniqueDestination(
                  for: oldSymbol,
                  destination: destination,
                  in: candidateSymbols
              )
        else {
            if requireCompleteEvidence {
                throw SDKRenameRepairBlocker(
                    "the candidate SDK does not contain exactly one stable "
                        + "destination matching \(destination)"
                )
            }
            return nil
        }
        guard let oldIdentifier = oldSymbol.preciseIdentifier,
              !oldIdentifier.isEmpty,
              let newIdentifier = newSymbol.preciseIdentifier,
              !newIdentifier.isEmpty
        else {
            throw SDKRenameRepairBlocker(
                "the old or replacement SDK symbol has no stable identity"
            )
        }
        guard replacementIsAvailable(
            newSymbol,
            for: finding,
            evidence: evidence,
            targetBuildContexts: targetBuildContexts
        ) else {
            let deployment = matchingTargetContext(
                for: finding,
                evidence: evidence,
                in: targetBuildContexts
            )?.deploymentTarget ?? "the selected deployment target"
            throw SDKRenameRepairBlocker(
                "the candidate SDK replacement is not available for "
                    + "deployment target \(deployment); changing this source "
                    + "occurrence would require an availability fallback"
            )
        }
        if !signaturesAreMechanicallyCompatible(oldSymbol, newSymbol),
           let structural = try structuralOptionSetPropertyRepair(
                finding: finding,
                evidence: evidence,
                oldSymbol: oldSymbol,
                newSymbol: newSymbol,
                destination: destination,
                candidateSymbols: candidateSymbols,
                projectRoot: projectRoot
           )
        {
            return structural
        }
        guard signaturesAreMechanicallyCompatible(oldSymbol, newSymbol) else {
            throw SDKRenameRepairBlocker(
                "the SDK destination \(destination) is not mechanically "
                    + "source-compatible with the old declaration"
            )
        }
        guard SDKRenameResolver.isIdentifierOnlyRename(
            from: oldSymbol,
            to: newSymbol
        ) else {
            throw SDKRenameRepairBlocker(
                "the SDK destination changes the owning declaration and "
                    + "requires a structural migration"
            )
        }
        guard let location = finding.location else {
            throw SDKRenameRepairBlocker(
                "the resolved project reference has no exact source location"
            )
        }
        let oldName = SDKRenameResolver.sourceTokenName(oldSymbol.baseName)
        let newName = SDKRenameResolver.sourceTokenName(newSymbol.baseName)
        guard isIdentifier(oldName), isIdentifier(newName) else {
            throw SDKRenameRepairBlocker(
                "the old or replacement SDK base name is not one Swift "
                    + "identifier token"
            )
        }
        guard oldName != newName else {
            throw SDKRenameRepairBlocker(
                "the SDK destination retains the same Swift base name and "
                    + "requires a non-identifier migration"
            )
        }
        let document = try RepairSourceDocument(
            root: projectRoot,
            file: sourceURL(location.path, root: projectRoot)
        )
        guard document.language == .swift else {
            throw SDKRenameRepairBlocker(
                "SDK rename repair currently requires Swift source"
            )
        }
        guard let range = exactIdentifierRange(
                  in: document,
                  location: location,
                  expected: oldName
              ) else {
            throw SDKRenameRepairBlocker(
                "the resolved source location does not identify the old "
                    + "SDK identifier token \(oldName)"
            )
        }
        return proposedSDKRepair(
            finding: finding,
            evidence: evidence,
            document: document,
            range: range,
            original: oldName,
            replacement: newName,
            source: .sdkRename,
            explanation:
                "The baseline reference resolves to \(oldIdentifier), and the candidate SDK"
                + " identifies the mechanically compatible replacement \(newIdentifier).",
            baselineSymbol: oldSymbol,
            candidateSymbol: newSymbol
        )
    }

    private static func replacementIsAvailable(
        _ symbol: SDKSymbol,
        for finding: Finding,
        evidence: SDKFindingEvidence,
        targetBuildContexts: [TargetBuildContext]
    ) -> Bool {
        guard let context = matchingTargetContext(
            for: finding,
            evidence: evidence,
            in: targetBuildContexts
        ), let deployment = VersionNumber(context.deploymentTarget)
        else {
            return true
        }
        let domain = normalizedPlatform(evidence.platform)
        guard let availability = symbol.availability.first(where: {
            normalizedPlatform($0.domain) == domain
        }) else {
            return true
        }
        if availability.isUnconditionallyUnavailable {
            return false
        }
        guard let introduced = availability.introduced,
              let introducedVersion = VersionNumber(introduced)
        else {
            return true
        }
        return introducedVersion <= deployment
    }

    private static func matchingTargetContext(
        for finding: Finding,
        evidence: SDKFindingEvidence,
        in contexts: [TargetBuildContext]
    ) -> TargetBuildContext? {
        let candidates = contexts.filter {
            $0.toolchainRole == "candidate"
                && normalizedPlatform($0.platform)
                    == normalizedPlatform(evidence.platform)
                && (finding.target == nil || $0.target == finding.target)
        }
        if candidates.count == 1 {
            return candidates[0]
        }
        let sdkMatches = contexts.filter {
            $0.toolchainRole == "candidate"
                && $0.sdkIdentifier == evidence.candidate.sdkIdentifier
                && (finding.target == nil || $0.target == finding.target)
        }
        return sdkMatches.count == 1 ? sdkMatches[0] : nil
    }

    private static func normalizedPlatform(_ value: String) -> String {
        switch value.lowercased()
            .replacingOccurrences(of: " ", with: "")
        {
        case "macos", "macosx": return "macos"
        case "ios", "iphoneos", "iphonesimulator": return "ios"
        case "tvos", "appletvos", "appletvsimulator": return "tvos"
        case "watchos", "watchsimulator": return "watchos"
        case "visionos", "xros", "xrsimulator": return "visionos"
        default: return value.lowercased()
        }
    }

    private static func structuralOptionSetPropertyRepair(
        finding: Finding,
        evidence: SDKFindingEvidence,
        oldSymbol: SDKSymbol,
        newSymbol: SDKSymbol,
        destination: String,
        candidateSymbols: [SDKSymbol],
        projectRoot: URL
    ) throws -> ProposedRepair? {
        guard oldSymbol.kind.contains("property"),
              newSymbol.kind.contains("property"),
              declaredValueType(oldSymbol.declaration) == "Bool",
              let candidateType = declaredValueType(newSymbol.declaration),
              candidateType != "Bool",
              let typeSymbol = uniqueTypeSymbol(
                candidateType,
                module: newSymbol.moduleName,
                in: candidateSymbols
              ),
              typeSymbol.relationships.contains(where: {
                  $0.kind == "conformsTo" && $0.target == "s:s9OptionSetP"
              }),
              let relativeDestination = relativeRenameDestination(
                destination,
                oldSymbol: oldSymbol
              ),
              relativeDestination.contains("."),
              hasStableDestinationPath(
                relativeDestination,
                oldSymbol: oldSymbol,
                candidateSymbols: candidateSymbols
              ),
              let option = uniqueOptionMember(
                for: oldSymbol,
                typeSymbol: typeSymbol,
                candidateSymbols: candidateSymbols
              ),
              let location = finding.location
        else {
            return nil
        }
        let members = Set(
            candidateSymbols.filter {
                $0.moduleName == newSymbol.moduleName
                    && $0.fullyQualifiedName.hasPrefix(
                        typeSymbol.fullyQualifiedName + "."
                    )
                    && $0.preciseIdentifier?.isEmpty == false
            }.map(\.baseName)
        )
        guard members.contains("contains"),
              members.contains("insert"),
              members.contains("remove")
        else { return nil }
        let document = try RepairSourceDocument(
            root: projectRoot,
            file: sourceURL(location.path, root: projectRoot)
        )
        guard document.language == .swift,
              let identifierRange = exactIdentifierRange(
                in: document,
                location: location,
                expected: oldSymbol.baseName
              )
        else { return nil }
        let edit = try optionSetSourceEdit(
            document: document,
            identifierRange: identifierRange,
            oldName: oldSymbol.baseName,
            destination: relativeDestination,
            option: option.baseName
        )
        guard let edit else { return nil }
        return proposedSDKRepair(
            finding: finding,
            evidence: evidence,
            document: document,
            range: edit.range,
            original: edit.original,
            replacement: edit.replacement,
            source: .sdkRename,
            explanation:
                "The exact SDK rename changes a Boolean property into the "
                + "OptionSet-backed path \(relativeDestination). The candidate "
                + "SDK supplies the stable \(option.baseName), contains, insert, "
                + "and remove members used by this bounded source migration.",
            baselineSymbol: oldSymbol,
            candidateSymbol: newSymbol,
            safety: .reviewRequired,
            requiresReview: true
        )
    }

    private static func optionSetSourceEdit(
        document: RepairSourceDocument,
        identifierRange: RepairSourceRange,
        oldName: String,
        destination: String,
        option: String
    ) throws -> (
        range: RepairSourceRange,
        original: String,
        replacement: String
    )? {
        guard let bounds = lineByteBounds(
            identifierRange.start.line,
            in: document.data
        ),
        let line = String(
            data: document.data.subdata(in: bounds),
            encoding: .utf8
        ) else { return nil }
        let localStart = identifierRange.start.utf8Offset - bounds.lowerBound
        let localEnd = identifierRange.end.utf8Offset - bounds.lowerBound
        guard localStart >= 0,
              localEnd <= line.utf8.count,
              let startUTF8 = line.utf8.index(
                line.utf8.startIndex,
                offsetBy: localStart,
                limitedBy: line.utf8.endIndex
              ),
              let endUTF8 = line.utf8.index(
                line.utf8.startIndex,
                offsetBy: localEnd,
                limitedBy: line.utf8.endIndex
              ),
              let start = String.Index(startUTF8, within: line),
              let end = String.Index(endUTF8, within: line),
              line[start..<end] == oldName
        else { return nil }
        let suffix = String(line[end...])
        if let assignment = booleanAssignment(suffix) {
            let leading = String(line.prefix { $0 == " " || $0 == "\t" })
            let receiver = String(line[line.index(
                line.startIndex,
                offsetBy: leading.count
            )..<start])
            guard receiver.hasSuffix("."),
                  receiver.range(
                    of: #"^[A-Za-z_][A-Za-z0-9_]*(?:[?!]?\.[A-Za-z_][A-Za-z0-9_]*)*\.$"#,
                    options: .regularExpression
                  ) != nil
            else { return nil }
            let operation = assignment ? "insert" : "remove"
            let replacement = leading + receiver + destination
                + ".\(operation)(.\(option))"
            return (
                RepairSourceRange(
                    start: sourcePosition(
                        offset: bounds.lowerBound,
                        in: document.data
                    ),
                    end: sourcePosition(
                        offset: bounds.upperBound,
                        in: document.data
                    )
                ),
                line,
                replacement
            )
        }
        guard !suffix.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).hasPrefix("=") else { return nil }
        return (
            identifierRange,
            oldName,
            destination + ".contains(.\(option))"
        )
    }

    private static func booleanAssignment(_ suffix: String) -> Bool? {
        let trimmed = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.range(of: #"^=\s*true\s*;?$"#, options: .regularExpression)
            != nil
        {
            return true
        }
        if trimmed.range(of: #"^=\s*false\s*;?$"#, options: .regularExpression)
            != nil
        {
            return false
        }
        return nil
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

    private static func uniqueTypeSymbol(
        _ type: String,
        module: String,
        in symbols: [SDKSymbol]
    ) -> SDKSymbol? {
        let qualified = type.hasPrefix(module + ".")
            ? type : module + "." + type
        let matches = symbols.filter {
            $0.moduleName == module
                && $0.fullyQualifiedName == qualified
                && $0.preciseIdentifier?.isEmpty == false
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func uniqueOptionMember(
        for oldSymbol: SDKSymbol,
        typeSymbol: SDKSymbol,
        candidateSymbols: [SDKSymbol]
    ) -> SDKSymbol? {
        let words = Set(camelCaseWords(oldSymbol.baseName))
        let matches = candidateSymbols.filter {
            $0.moduleName == typeSymbol.moduleName
                && $0.fullyQualifiedName.hasPrefix(
                    typeSymbol.fullyQualifiedName + "."
                )
                && $0.kind.contains("property")
                && $0.preciseIdentifier?.isEmpty == false
                && isIdentifier($0.baseName)
                && words.contains($0.baseName.lowercased())
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func camelCaseWords(_ value: String) -> [String] {
        guard let expression = try? NSRegularExpression(
            pattern: #"[A-Z]?[a-z]+|[A-Z]+(?![a-z])|[0-9]+"#
        ) else { return [] }
        let range = NSRange(value.startIndex..., in: value)
        return expression.matches(in: value, range: range).compactMap {
            Range($0.range, in: value).map {
                value[$0].lowercased()
            }
        }
    }

    private static func relativeRenameDestination(
        _ destination: String,
        oldSymbol: SDKSymbol
    ) -> String? {
        let head = destination.split(separator: "(", maxSplits: 1)
            .first.map(String.init) ?? destination
        var components = head.split(separator: ".").map(String.init)
        if components.first == oldSymbol.moduleName {
            components.removeFirst()
        }
        var owner = oldSymbol.fullyQualifiedName.split(separator: ".")
            .map(String.init)
        if owner.first == oldSymbol.moduleName {
            owner.removeFirst()
        }
        owner.removeLast()
        if components.starts(with: owner) {
            components.removeFirst(owner.count)
        }
        guard !components.isEmpty,
              components.allSatisfy(isIdentifier)
        else { return nil }
        return components.joined(separator: ".")
    }

    private static func hasStableDestinationPath(
        _ destination: String,
        oldSymbol: SDKSymbol,
        candidateSymbols: [SDKSymbol]
    ) -> Bool {
        guard let first = destination.split(separator: ".").first else {
            return false
        }
        let owner = oldSymbol.fullyQualifiedName.split(separator: ".")
            .dropLast().joined(separator: ".")
        let expected = owner + "." + first
        let matches = candidateSymbols.filter {
            $0.moduleName == oldSymbol.moduleName
                && $0.fullyQualifiedName == expected
                && $0.preciseIdentifier?.isEmpty == false
                && $0.declaration?.isEmpty == false
        }
        return matches.count == 1
    }

    private static func parameterLabelRepair(
        finding: Finding,
        evidence: SDKFindingEvidence,
        oldSymbol: SDKSymbol,
        candidateSymbols: [SDKSymbol],
        projectRoot: URL
    ) throws -> ProposedRepair? {
        guard let oldIdentifier = oldSymbol.preciseIdentifier,
              let newSymbol = uniqueMechanicalCandidate(
                  for: oldSymbol,
                  in: candidateSymbols
              ),
              let newIdentifier = newSymbol.preciseIdentifier,
              oldSymbol.baseName == newSymbol.baseName,
              oldSymbol.returnType == newSymbol.returnType,
              oldSymbol.concurrency == newSymbol.concurrency,
              let location = finding.location
        else {
            return nil
        }
        guard let labelChange = uniqueLabelChange(
            baseline: oldSymbol.parameters,
            candidate: newSymbol.parameters
        ),
              let oldLabel = labelChange.baseline.externalName,
              let newLabel = labelChange.candidate.externalName,
              oldLabel != "_",
              newLabel != "_",
              isIdentifier(oldLabel),
              isIdentifier(newLabel)
        else {
            return nil
        }
        let document = try RepairSourceDocument(
            root: projectRoot,
            file: sourceURL(location.path, root: projectRoot)
        )
        guard document.language == .swift,
              let functionRange = exactIdentifierRange(
                  in: document,
                  location: location,
                  expected: oldSymbol.baseName
              ),
              let labelRange = exactCallLabelRange(
                  in: document,
                  after: functionRange,
                  expected: oldLabel
              )
        else {
            return nil
        }
        return proposedSDKRepair(
            finding: finding,
            evidence: evidence,
            document: document,
            range: labelRange,
            original: oldLabel,
            replacement: newLabel,
            source: .mechanicalSignatureChange,
            explanation:
                "The resolved SDK symbol \(oldIdentifier) retains its parameter types,"
                + " return type, and concurrency contract; exactly one call-site label"
                + " changes in candidate symbol \(newIdentifier).",
            baselineSymbol: oldSymbol,
            candidateSymbol: newSymbol
        )
    }

    private static func proposedSDKRepair(
        finding: Finding,
        evidence: SDKFindingEvidence,
        document: RepairSourceDocument,
        range: RepairSourceRange,
        original: String,
        replacement: String,
        source: RepairEvidenceSource,
        explanation: String,
        baselineSymbol: SDKSymbol,
        candidateSymbol: SDKSymbol,
        safety: RepairSafetyClassification = .safe,
        requiresReview: Bool = false
    ) -> ProposedRepair {
        let repairIdentifier = RepairFingerprint.identifier([
            source.rawValue,
            finding.findingID,
            document.relativePath,
            String(range.start.utf8Offset),
            String(range.end.utf8Offset),
            original,
            replacement,
            document.fingerprint.digest,
            baselineSymbol.preciseIdentifier ?? "",
            candidateSymbol.preciseIdentifier ?? "",
        ])
        return ProposedRepair(
            repairIdentifier: repairIdentifier,
            relatedFindingIdentifier: finding.findingID,
            evidenceSource: source,
            language: .swift,
            filePath: document.relativePath,
            sourceRange: range,
            originalText: original,
            replacementText: replacement,
            fileFingerprint: document.fingerprint,
            confidence: .high,
            safety: safety,
            explanation: explanation,
            verificationRequirement: .candidateBuild,
            toolchains: RepairToolchainEvidence(
                baseline: evidence.baseline,
                candidate: evidence.candidate
            ),
            symbols: RepairSymbolEvidence(
                baselinePreciseIdentifier: baselineSymbol.preciseIdentifier,
                candidatePreciseIdentifier: candidateSymbol.preciseIdentifier,
                moduleName: baselineSymbol.moduleName,
                baselineDeclaration: baselineSymbol.declaration,
                candidateDeclaration: candidateSymbol.declaration
            ),
            requiresReview: requiresReview
        )
    }

    private static func signaturesAreMechanicallyCompatible(
        _ old: SDKSymbol,
        _ new: SDKSymbol
    ) -> Bool {
        old.parameters.count == new.parameters.count
            && zip(old.parameters, new.parameters).allSatisfy { pair in
                pair.0.type == pair.1.type
                    && pair.0.externalName == pair.1.externalName
            }
            && old.returnType == new.returnType
            && old.concurrency == new.concurrency
            && old.kind == new.kind
    }

    private static func renameDestination(
        _ symbol: SDKSymbol,
        evidence: SDKFindingEvidence
    ) -> String? {
        symbol.renamedDestination
            ?? symbol.availability.compactMap(\.renamed).first
            ?? evidence.newAvailability.compactMap(\.renamed).first
            ?? evidence.oldAvailability.compactMap(\.renamed).first
    }

    private static func uniqueSymbol(
        preciseIdentifier: String,
        module: String,
        in symbols: [SDKSymbol]
    ) -> SDKSymbol? {
        let matches = symbols.filter {
            $0.moduleName == module && $0.preciseIdentifier == preciseIdentifier
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func uniqueMechanicalCandidate(
        for old: SDKSymbol,
        in symbols: [SDKSymbol]
    ) -> SDKSymbol? {
        let matches = symbols.filter {
            $0.moduleName == old.moduleName
                && $0.baseName == old.baseName
                && $0.kind == old.kind
                && $0.preciseIdentifier != nil
                && $0.returnType == old.returnType
                && $0.concurrency == old.concurrency
                && uniqueLabelChange(
                    baseline: old.parameters,
                    candidate: $0.parameters
                ) != nil
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func uniqueLabelChange(
        baseline: [SDKFunctionParameter],
        candidate: [SDKFunctionParameter]
    ) -> (
        baseline: SDKFunctionParameter,
        candidate: SDKFunctionParameter
    )? {
        typealias Change = (
            baseline: SDKFunctionParameter,
            candidate: SDKFunctionParameter
        )
        var solutions: [Change] = []

        func walk(
            baselineIndex: Int,
            candidateIndex: Int,
            change: Change?
        ) {
            if solutions.count > 1 {
                return
            }
            if baselineIndex == baseline.count {
                guard candidate.dropFirst(candidateIndex).allSatisfy(isOmittable),
                      let change
                else {
                    return
                }
                solutions.append(change)
                return
            }
            guard candidateIndex < candidate.count else {
                return
            }
            let old = baseline[baselineIndex]
            let new = candidate[candidateIndex]
            if old.type == new.type {
                if old.externalName == new.externalName {
                    walk(
                        baselineIndex: baselineIndex + 1,
                        candidateIndex: candidateIndex + 1,
                        change: change
                    )
                } else if change == nil {
                    walk(
                        baselineIndex: baselineIndex + 1,
                        candidateIndex: candidateIndex + 1,
                        change: (old, new)
                    )
                }
            }
            if isOmittable(new) {
                walk(
                    baselineIndex: baselineIndex,
                    candidateIndex: candidateIndex + 1,
                    change: change
                )
            }
        }

        walk(baselineIndex: 0, candidateIndex: 0, change: nil)
        return solutions.count == 1 ? solutions[0] : nil
    }

    private static func isOmittable(
        _ parameter: SDKFunctionParameter
    ) -> Bool {
        parameter.hasDefaultValue == true
            || parameter.type?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).hasSuffix("...") == true
    }

    private static func exactIdentifierRange(
        in document: RepairSourceDocument,
        location: SourceLocation,
        expected: String
    ) -> RepairSourceRange? {
        guard let line = location.line,
              let column = location.column,
              line > 0,
              column > 0,
              let lineBounds = lineByteBounds(line, in: document.data)
        else {
            return nil
        }
        let lineData = document.data.subdata(in: lineBounds)
        guard let lineText = String(data: lineData, encoding: .utf8),
              let characterIndex = lineText.index(
                  lineText.startIndex,
                  offsetBy: column - 1,
                  limitedBy: lineText.endIndex
              )
        else {
            return nil
        }
        let exactStart: String.Index
        let suffix = lineText[characterIndex...]
        if suffix.hasPrefix(expected),
           identifierBoundariesHold(
                in: lineText,
                start: characterIndex,
                length: expected.count
           )
        {
            exactStart = characterIndex
        } else {
            let pattern = #"\b"#
                + NSRegularExpression.escapedPattern(for: expected)
                + #"\b"#
            guard let expression = try? NSRegularExpression(
                pattern: pattern
            ) else { return nil }
            let searchRange = NSRange(lineText.startIndex..., in: lineText)
            let matches = expression.matches(
                in: lineText,
                range: searchRange
            )
            guard matches.count == 1,
                  let match = matches.first,
                  let range = Range(match.range, in: lineText)
            else { return nil }
            exactStart = range.lowerBound
        }
        let localStart = lineText[..<exactStart].utf8.count
        let localEnd = localStart + expected.utf8.count
        let startOffset = lineBounds.lowerBound + localStart
        let endOffset = lineBounds.lowerBound + localEnd
        let start = sourcePosition(offset: startOffset, in: document.data)
        let end = sourcePosition(offset: endOffset, in: document.data)
        return RepairSourceRange(
            start: start,
            end: end
        )
    }

    private static func identifierBoundariesHold(
        in text: String,
        start: String.Index,
        length: Int
    ) -> Bool {
        let beforeIsIdentifier = start > text.startIndex
            && isIdentifierContinuation(text[text.index(before: start)])
        guard let end = text.index(
            start,
            offsetBy: length,
            limitedBy: text.endIndex
        ) else { return false }
        let afterIsIdentifier = end < text.endIndex
            && isIdentifierContinuation(text[end])
        return !beforeIsIdentifier && !afterIsIdentifier
    }

    private static func exactCallLabelRange(
        in document: RepairSourceDocument,
        after functionRange: RepairSourceRange,
        expected: String
    ) -> RepairSourceRange? {
        let bytes = Array(document.data)
        var index = functionRange.end.utf8Offset
        while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x09 {
            index += 1
        }
        guard index < bytes.count, bytes[index] == 0x28 else {
            return nil
        }
        let callStart = index
        var depth = 0
        var callEnd: Int?
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x22 || byte == 0x7B || byte == 0x7D || byte == 0x23 {
                return nil
            }
            if byte == 0x28 {
                depth += 1
            } else if byte == 0x29 {
                depth -= 1
                if depth == 0 {
                    callEnd = index
                    break
                }
            }
            index += 1
        }
        guard let callEnd,
              let call = String(
                  data: document.data.subdata(in: callStart..<(callEnd + 1)),
                  encoding: .utf8
              )
        else {
            return nil
        }
        let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: expected)
            + #"\s*:"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              expression.numberOfMatches(
                  in: call,
                  range: NSRange(call.startIndex..., in: call)
              ) == 1,
              let match = expression.firstMatch(
                  in: call,
                  range: NSRange(call.startIndex..., in: call)
              ),
              let tokenRange = Range(
                  NSRange(location: match.range.location, length: expected.utf16.count),
                  in: call
              )
        else {
            return nil
        }
        let localStart = call[..<tokenRange.lowerBound].utf8.count
        let startOffset = callStart + localStart
        let endOffset = startOffset + expected.utf8.count
        let startPosition = sourcePosition(offset: startOffset, in: document.data)
        let endPosition = sourcePosition(offset: endOffset, in: document.data)
        return RepairSourceRange(start: startPosition, end: endPosition)
    }

    private static func sourcePosition(offset: Int, in data: Data) -> RepairSourcePosition {
        let prefix = data.prefix(offset)
        let line = 1 + prefix.count(where: { $0 == 0x0A })
        let lineStart = prefix.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
        let columnData = prefix.dropFirst(lineStart)
        let column = String(decoding: columnData, as: UTF8.self).count + 1
        return RepairSourcePosition(line: line, column: column, utf8Offset: offset)
    }

    private static func lineByteBounds(_ line: Int, in data: Data) -> Range<Int>? {
        var currentLine = 1
        var lower = 0
        for (offset, byte) in data.enumerated() where byte == 0x0A {
            if currentLine == line {
                let upper = offset > lower && data[offset - 1] == 0x0D
                    ? offset - 1
                    : offset
                return lower..<upper
            }
            currentLine += 1
            lower = offset + 1
        }
        return currentLine == line ? lower..<data.count : nil
    }

    private static func sourceURL(_ path: String, root: URL) -> URL {
        NSString(string: path).isAbsolutePath
            ? URL(fileURLWithPath: path)
            : root.appendingPathComponent(path)
    }

    private static func isIdentifier(_ value: String) -> Bool {
        value.range(
            of: #"^[A-Za-z_][A-Za-z0-9_]*$"#,
            options: .regularExpression
        ) != nil
    }

    private static func isIdentifierContinuation(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }
}

private struct SDKRenameRepairBlocker: LocalizedError {
    let reason: String

    init(_ reason: String) {
        self.reason = reason
    }

    var errorDescription: String? {
        reason
    }
}
