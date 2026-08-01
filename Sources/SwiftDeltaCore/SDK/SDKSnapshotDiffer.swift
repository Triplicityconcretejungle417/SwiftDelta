//===--- SDKSnapshotDiffer.swift - SwiftDelta ------------------------------------------===//
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

/// Compares normalized SDK snapshots without relying on built-in API rules.
public enum SDKSnapshotDiffer {
    public static func compare(
        baseline: SDKSnapshot,
        candidate: SDKSnapshot
    ) -> [SDKSymbolChange] {
        // A module is comparable only when extraction succeeded on both sides.
        // Treating an extraction failure as an empty module would fabricate
        // removals for every baseline symbol.
        let comparableModules = baseline.successfullyExtractedModules
            .intersection(candidate.successfullyExtractedModules)
        // A malformed or partially merged snapshot can contain repeated
        // identifiers. Exact matching is authoritative only when the
        // candidate identity is unique; Dictionary(uniqueKeysWithValues:)
        // would trap before the comparison could report conservative evidence.
        let candidateByID = Dictionary(grouping: candidate.symbols, by: \.id)
        let baselineFamilies = Dictionary(grouping: baseline.symbols, by: semanticFamilyKey)
        let candidateFamilies = Dictionary(grouping: candidate.symbols, by: semanticFamilyKey)
        var changes: [SDKSymbolChange] = []

        for oldSymbol in baseline.symbols
            where comparableModules.contains(oldSymbol.moduleName)
        {
            if let candidates = candidateByID[oldSymbol.id],
               candidates.count == 1,
               let newSymbol = candidates.first
            {
                changes.append(
                    contentsOf: compareSymbol(
                        oldSymbol,
                        newSymbol,
                        platform: baseline.identity.platform,
                        matchConfidence: .high
                    )
                )
                continue
            }
            if let candidates = candidateByID[oldSymbol.id],
               candidates.count > 1
            {
                changes.append(
                    SDKSymbolChange(
                        kind: .removed,
                        baseline: oldSymbol,
                        candidate: nil,
                        matchConfidence: .low,
                        observedChange:
                            "\(oldSymbol.fullyQualifiedName) has "
                            + "\(candidates.count) candidate declarations with "
                            + "the same normalized identity. The malformed "
                            + "identity set cannot establish source removal."
                    )
                )
                continue
            }

            let family = semanticFamilyKey(oldSymbol)
            let oldFamily = baselineFamilies[family] ?? []
            let newFamily = candidateFamilies[family] ?? []
            let evaluations = newFamily.map {
                (
                    symbol: $0,
                    compatibility: SDKSourceCompatibilityEvaluator.evaluate(
                        baseline: oldSymbol,
                        candidate: $0,
                        platform: baseline.identity.platform
                    )
                )
            }
            let compatibleCandidates = evaluations.filter {
                if case .compatible = $0.compatibility {
                    return true
                }
                return false
            }
            if compatibleCandidates.count == 1 {
                // Structural binding found one viable declaration. Candidate
                // compiler resolution at the concrete expression remains the
                // stronger source-compatibility signal.
                continue
            }
            if compatibleCandidates.count > 1 {
                changes.append(
                    SDKSymbolChange(
                        kind: .removed,
                        baseline: oldSymbol,
                        candidate: nil,
                        matchConfidence: .low,
                        observedChange:
                            "\(oldSymbol.fullyQualifiedName) is absent by stable "
                            + "identity, but multiple candidate overloads can "
                            + "structurally bind the baseline arguments. Candidate "
                            + "compiler resolution is required to determine whether "
                            + "the source expression is ambiguous."
                    )
                )
                continue
            }
            let uncertainCandidates = evaluations.filter {
                if case .uncertain = $0.compatibility {
                    return true
                }
                return false
            }
            if !uncertainCandidates.isEmpty {
                let reasons = Set(
                    uncertainCandidates.compactMap {
                        if case .uncertain(let reason) = $0.compatibility {
                            return reason
                        }
                        return nil
                    }
                ).sorted().joined(separator: "; ")
                changes.append(
                    SDKSymbolChange(
                        kind: .removed,
                        baseline: oldSymbol,
                        candidate: nil,
                        matchConfidence: .low,
                        observedChange:
                            "\(oldSymbol.fullyQualifiedName) is absent by stable "
                            + "identity, but source compatibility could not be "
                            + "confirmed from candidate declarations"
                            + (reasons.isEmpty ? "." : ": \(reasons).")
                    )
                )
                continue
            }
            if oldSymbol.preciseIdentifier == nil,
               oldFamily.count == 1,
               newFamily.count == 1,
               let newSymbol = newFamily.first
            {
                changes.append(
                    contentsOf: compareSymbol(
                        oldSymbol,
                        newSymbol,
                        platform: baseline.identity.platform,
                        matchConfidence: .medium
                    )
                )
                continue
            }

            if let renamed = oldSymbol.renamedDestination {
                let replacement = SDKRenameResolver.uniqueDestination(
                    for: oldSymbol,
                    destination: renamed,
                    in: candidate.symbols
                )
                changes.append(
                    SDKSymbolChange(
                        kind: .renamed,
                        baseline: oldSymbol,
                        candidate: replacement,
                        matchConfidence: replacement == nil ? .low : .high,
                        observedChange: "\(oldSymbol.fullyQualifiedName) is absent from the candidate SDK; the baseline SDK marks it as renamed to \(renamed)."
                    )
                )
            } else {
                changes.append(
                    SDKSymbolChange(
                        kind: .removed,
                        baseline: oldSymbol,
                        candidate: nil,
                        observedChange: "\(oldSymbol.fullyQualifiedName) is present in the baseline SDK and absent from the candidate SDK."
                    )
                )
            }
        }
        return changes.sorted(by: changeOrder)
    }

    private static func compareSymbol(
        _ old: SDKSymbol,
        _ new: SDKSymbol,
        platform: String,
        matchConfidence: Confidence
    ) -> [SDKSymbolChange] {
        var changes: [SDKSymbolChange] = []
        let oldAvailability = relevantAvailability(old.availability, platform: platform)
        let newAvailability = relevantAvailability(new.availability, platform: platform)
        let oldDeprecated = oldAvailability.contains {
            $0.deprecated != nil || $0.isUnconditionallyDeprecated
        }
        let newDeprecated = newAvailability.contains {
            $0.deprecated != nil || $0.isUnconditionallyDeprecated
        }
        if !oldDeprecated, newDeprecated {
            changes.append(
                change(
                    .newlyDeprecated,
                    old,
                    new,
                    matchConfidence,
                    "The candidate SDK newly marks \(old.fullyQualifiedName) as deprecated."
                )
            )
        }
        let oldUnavailable = unavailable(
            symbol: old,
            availability: oldAvailability
        )
        let newUnavailable = unavailable(
            symbol: new,
            availability: newAvailability
        )
        if !oldUnavailable, newUnavailable {
            changes.append(
                change(
                    .newlyUnavailable,
                    old,
                    new,
                    matchConfidence,
                    "The candidate SDK newly marks \(old.fullyQualifiedName) as unavailable."
                )
            )
        }
        if old.renamedDestination != new.renamedDestination,
           let destination = new.renamedDestination
        {
            changes.append(
                change(
                    .renamed,
                    old,
                    new,
                    matchConfidence,
                    "The candidate SDK marks \(old.fullyQualifiedName) as renamed to \(destination)."
                )
            )
        }

        let oldLabels = old.parameters.map(\.externalName)
        let newLabels = new.parameters.map(\.externalName)
        if oldLabels != newLabels {
            changes.append(
                change(
                    .parameterLabelsChanged,
                    old,
                    new,
                    matchConfidence,
                    "Parameter labels changed from \(display(oldLabels)) to \(display(newLabels))."
                )
            )
        }
        let oldParameterTypes = old.parameters.map(\.type)
        let newParameterTypes = new.parameters.map(\.type)
        if oldParameterTypes != newParameterTypes {
            changes.append(
                change(
                    .parameterTypesChanged,
                    old,
                    new,
                    matchConfidence,
                    "Parameter types changed from \(display(oldParameterTypes)) to \(display(newParameterTypes))."
                )
            )
        }
        if old.returnType != new.returnType {
            changes.append(
                change(
                    .returnTypeChanged,
                    old,
                    new,
                    matchConfidence,
                    "The return type changed from \(old.returnType ?? "<unspecified>") to \(new.returnType ?? "<unspecified>")."
                )
            )
        }
        if normalizedSignature(old.signature) != normalizedSignature(new.signature) {
            changes.append(
                change(
                    .signatureChanged,
                    old,
                    new,
                    matchConfidence,
                    "The SDK declaration signature changed."
                )
            )
        }
        if normalizedAvailability(oldAvailability) != normalizedAvailability(newAvailability) {
            changes.append(
                change(
                    .availabilityChanged,
                    old,
                    new,
                    matchConfidence,
                    "Availability metadata changed for \(platform) from \(availabilityText(oldAvailability)) to \(availabilityText(newAvailability))."
                )
            )
        }
        if old.propertyReadable != new.propertyReadable
            || old.propertyWritable != new.propertyWritable
        {
            changes.append(
                change(
                    .propertyAccessChanged,
                    old,
                    new,
                    matchConfidence,
                    "Property access changed from \(accessText(old)) to \(accessText(new))."
                )
            )
        }
        if old.isProtocolRequirement != new.isProtocolRequirement
            || relationshipTargets(old, kinds: ["requirementOf", "optionalRequirementOf"])
                != relationshipTargets(new, kinds: ["requirementOf", "optionalRequirementOf"])
        {
            changes.append(
                change(
                    .protocolRequirementChanged,
                    old,
                    new,
                    matchConfidence,
                    "Protocol requirement membership changed."
                )
            )
        }
        if relationshipTargets(old, kinds: ["inheritsFrom"])
            != relationshipTargets(new, kinds: ["inheritsFrom"])
        {
            changes.append(
                change(
                    .inheritanceChanged,
                    old,
                    new,
                    matchConfidence,
                    "Inheritance relationships changed."
                )
            )
        }
        if relationshipTargets(old, kinds: ["conformsTo"])
            != relationshipTargets(new, kinds: ["conformsTo"])
        {
            changes.append(
                change(
                    .conformanceChanged,
                    old,
                    new,
                    matchConfidence,
                    "Protocol conformances changed."
                )
            )
        }
        if old.concurrency != new.concurrency {
            changes.append(
                change(
                    .concurrencyChanged,
                    old,
                    new,
                    matchConfidence,
                    "Swift concurrency metadata changed from \(concurrencyText(old.concurrency)) to \(concurrencyText(new.concurrency))."
                )
            )
        }
        return changes
    }

    private static func unavailable(
        symbol: SDKSymbol,
        availability: [SDKAvailability]
    ) -> Bool {
        if availability.isEmpty {
            return symbol.isUnavailable && symbol.availability.isEmpty
        }
        return availability.contains { $0.isUnconditionallyUnavailable }
    }

    private static func change(
        _ kind: SDKChangeKind,
        _ old: SDKSymbol,
        _ new: SDKSymbol,
        _ confidence: Confidence,
        _ description: String
    ) -> SDKSymbolChange {
        SDKSymbolChange(
            kind: kind,
            baseline: old,
            candidate: new,
            matchConfidence: confidence,
            observedChange: description
        )
    }

    private static func semanticFamilyKey(_ symbol: SDKSymbol) -> String {
        let path = symbol.fullyQualifiedName.split(separator: ".").map(String.init)
        let parent = path.dropLast().joined(separator: ".")
        return [
            symbol.moduleName,
            kindFamily(symbol.kind),
            parent,
            symbol.baseName,
        ].joined(separator: "|")
    }

    private static func kindFamily(_ kind: String) -> String {
        if kind.contains("method") || kind.contains("func") {
            return "function"
        }
        if kind.contains("property") || kind.contains("var") {
            return "property"
        }
        return kind
    }

    private static func relationshipTargets(
        _ symbol: SDKSymbol,
        kinds: Set<String>
    ) -> [String] {
        symbol.relationships
            .filter { kinds.contains($0.kind) }
            .map(\.target)
            .sorted()
    }

    private static func normalizedAvailability(
        _ values: [SDKAvailability]
    ) -> [String] {
        Array(Set(values.map { value in
            [
                canonicalPlatform(value.domain),
                normalizedVersion(value.introduced),
                normalizedVersion(value.deprecated),
                normalizedVersion(value.obsoleted),
                value.isUnconditionallyDeprecated ? "deprecated" : "",
                value.isUnconditionallyUnavailable ? "unavailable" : "",
                normalizedMetadataText(value.renamed),
                normalizedMetadataText(value.message),
            ].joined(separator: "|")
        })).sorted()
    }

    private static func normalizedVersion(_ value: String?) -> String {
        guard let value else { return "" }
        var components = value.split(separator: ".").map(String.init)
        guard components.allSatisfy({ Int($0) != nil }) else {
            return value.lowercased()
        }
        while components.count > 1, components.last == "0" {
            components.removeLast()
        }
        return components.joined(separator: ".")
    }

    private static func normalizedMetadataText(_ value: String?) -> String {
        value?
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
    }

    static func relevantAvailability(
        _ values: [SDKAvailability],
        platform: String
    ) -> [SDKAvailability] {
        let selected = canonicalPlatform(platform)
        return values.filter { value in
            let domain = canonicalPlatform(value.domain)
            return domain == selected || domain == "*"
        }
    }

    private static func canonicalPlatform(_ value: String) -> String {
        let lower = value.lowercased()
        if lower.hasPrefix("ios") || lower.hasPrefix("iphone") {
            return "ios"
        }
        if lower.hasPrefix("macos") {
            return "macos"
        }
        if lower.hasPrefix("tvos") || lower.hasPrefix("appletv") {
            return "tvos"
        }
        if lower.hasPrefix("watchos") || lower.hasPrefix("watch") {
            return "watchos"
        }
        if lower.hasPrefix("visionos") || lower.hasPrefix("xros") {
            return "visionos"
        }
        return lower.replacingOccurrences(of: " simulator", with: "")
    }

    private static func availabilityText(_ values: [SDKAvailability]) -> String {
        values.isEmpty ? "<none>" : values.map(\.description).sorted().joined(separator: "; ")
    }

    private static func accessText(_ symbol: SDKSymbol) -> String {
        switch (symbol.propertyReadable, symbol.propertyWritable) {
        case (true, true): "read-write"
        case (true, false): "read-only"
        case (false, true): "write-only"
        default: "unspecified"
        }
    }

    private static func concurrencyText(_ value: SDKConcurrencyMetadata) -> String {
        var values: [String] = []
        if let actorIsolation = value.actorIsolation {
            values.append("@\(actorIsolation)")
        }
        if value.isAsync {
            values.append("async")
        }
        if value.isSendable {
            values.append("Sendable")
        }
        if value.isNonisolated {
            values.append("nonisolated")
        }
        if value.isPreconcurrency {
            values.append("@preconcurrency")
        }
        return values.isEmpty ? "<none>" : values.joined(separator: " ")
    }

    private static func display(_ values: [String?]) -> String {
        "[" + values.map { $0 ?? "_" }.joined(separator: ", ") + "]"
    }

    private static func normalizedSignature(_ value: String?) -> String {
        guard let value else { return "" }
        let normalizedWhitespace = value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let keyword = normalizedWhitespace.range(
            of: #"\b(func|init|subscript|var|let|class|struct|enum|protocol|typealias)\b"#,
            options: .regularExpression
        ) else {
            return normalizedWhitespace
        }
        let prefix = String(normalizedWhitespace[..<keyword.lowerBound])
        let declaration = String(normalizedWhitespace[keyword.lowerBound...])
        let expression = try? NSRegularExpression(
            pattern: #"@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?"#
        )
        let range = NSRange(prefix.startIndex..<prefix.endIndex, in: prefix)
        let attributes = expression?.matches(in: prefix, range: range).compactMap {
            Range($0.range, in: prefix).map { String(prefix[$0]) }
        } ?? []
        var remainingPrefix = prefix
        for attribute in attributes {
            remainingPrefix = remainingPrefix.replacingOccurrences(
                of: attribute,
                with: ""
            )
        }
        let orderedPrefix = (
            attributes.sorted()
                + remainingPrefix.split(whereSeparator: \.isWhitespace).map(String.init)
        ).joined(separator: " ")
        return [orderedPrefix, declaration]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
    }

    private static func changeOrder(_ lhs: SDKSymbolChange, _ rhs: SDKSymbolChange) -> Bool {
        let left = (lhs.baseline.moduleName, lhs.baseline.fullyQualifiedName, lhs.kind.rawValue)
        let right = (rhs.baseline.moduleName, rhs.baseline.fullyQualifiedName, rhs.kind.rawValue)
        return left < right
    }
}
