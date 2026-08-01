//===--- SDKSourceCompatibility.swift - SwiftDelta ------------------------------------------===//
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

enum SDKSourceCompatibility: Equatable {
    case compatible(String)
    case incompatible(String)
    case uncertain(String)
}

/// Conservatively evaluates whether a candidate declaration can accept source
/// that supplied every baseline parameter. Actual candidate compiler
/// resolution remains stronger evidence than this structural fallback.
enum SDKSourceCompatibilityEvaluator {
    static func evaluate(
        baseline: SDKSymbol,
        candidate: SDKSymbol,
        platform: String
    ) -> SDKSourceCompatibility {
        guard baseline.moduleName == candidate.moduleName,
              baseline.baseName == candidate.baseName,
              callableKind(baseline) == callableKind(candidate)
        else {
            return .incompatible("the declarations are not in the same callable family")
        }
        guard instanceDomain(baseline) == instanceDomain(candidate) else {
            return .incompatible("static, class, and instance access do not match")
        }
        let candidateAvailability = SDKSnapshotDiffer.relevantAvailability(
            candidate.availability,
            platform: platform
        )
        if candidateAvailability.contains(
            where: \.isUnconditionallyUnavailable
        )
            || (candidate.isUnavailable && candidate.availability.isEmpty)
        {
            return .incompatible("the candidate declaration is unavailable")
        }
        if availabilityBecameMoreRestrictive(
            baseline: baseline,
            candidate: candidate,
            platform: platform
        ) {
            return .uncertain(
                "the candidate declaration has a newer platform availability boundary"
            )
        }

        let effects = effectCompatibility(
            baseline: baseline,
            candidate: candidate
        )
        switch effects {
        case .incompatible, .uncertain:
            return effects
        case .compatible:
            break
        }

        let binding = bindParameters(
            baseline: baseline.parameters,
            candidate: candidate.parameters
        )
        guard case .compatible = binding else {
            return binding
        }

        switch returnCompatibility(
            baseline.returnType,
            candidate.returnType
        ) {
        case .compatible:
            break
        case .incompatible(let reason):
            return .incompatible(reason)
        case .uncertain(let reason):
            return .uncertain(reason)
        }

        if genericConstraintsStrengthened(
            baseline: baseline.signature ?? baseline.declaration,
            candidate: candidate.signature ?? candidate.declaration
        ) {
            return .uncertain(
                "the candidate declaration may impose stronger generic constraints"
            )
        }
        return .compatible(
            "candidate parameters accept the baseline labels and types, and "
                + "all additional parameters are omittable"
        )
    }

    private static func bindParameters(
        baseline: [SDKFunctionParameter],
        candidate: [SDKFunctionParameter]
    ) -> SDKSourceCompatibility {
        var baselineIndex = 0
        var candidateIndex = 0
        var encounteredUnknownDefault = false

        while candidateIndex < candidate.count {
            let newParameter = candidate[candidateIndex]
            if baselineIndex < baseline.count,
               parametersBind(
                   baseline[baselineIndex],
                   newParameter
               )
            {
                baselineIndex += 1
                candidateIndex += 1
                continue
            }
            if isOmittable(newParameter) == true {
                candidateIndex += 1
                continue
            }
            if isOmittable(newParameter) == nil {
                encounteredUnknownDefault = true
                candidateIndex += 1
                continue
            }
            return .incompatible(
                "a required candidate parameter prevents source-argument binding"
            )
        }

        guard baselineIndex == baseline.count else {
            return .incompatible(
                "candidate labels, ordering, or parameter types cannot bind all baseline arguments"
            )
        }
        if encounteredUnknownDefault {
            return .uncertain(
                "candidate metadata does not establish whether every added parameter is omittable"
            )
        }
        return .compatible("all baseline arguments bind to candidate parameters")
    }

    private static func parametersBind(
        _ baseline: SDKFunctionParameter,
        _ candidate: SDKFunctionParameter
    ) -> Bool {
        guard normalizedLabel(baseline.externalName)
                == normalizedLabel(candidate.externalName)
        else {
            return false
        }
        return inputTypeCompatibility(
            baseline.type,
            candidate.type
        )
    }

    private static func isOmittable(
        _ parameter: SDKFunctionParameter
    ) -> Bool? {
        if parameter.hasDefaultValue == true {
            return true
        }
        if isVariadic(parameter.type) {
            return true
        }
        return parameter.hasDefaultValue
    }

    private static func inputTypeCompatibility(
        _ baseline: String?,
        _ candidate: String?
    ) -> Bool {
        guard let baseline, let candidate else {
            return baseline == nil && candidate == nil
        }
        let old = parsedType(baseline)
        let new = parsedType(candidate)
        guard restrictionCompatibility(old: old, new: new) else {
            return false
        }
        if old.core == new.core {
            return true
        }
        // Widening an input to optional still accepts the previous nonoptional
        // argument. Other conversions require compiler evidence.
        return !old.isOptional
            && new.isOptional
            && old.core == new.core
    }

    private static func returnCompatibility(
        _ baseline: String?,
        _ candidate: String?
    ) -> SDKSourceCompatibility {
        guard let baseline, let candidate else {
            return baseline == candidate
                ? .compatible("return types match")
                : .uncertain("one declaration omits structured return-type metadata")
        }
        let old = parsedType(baseline)
        let new = parsedType(candidate)
        if old.core == new.core, old.isOptional == new.isOptional {
            return .compatible("return types match")
        }
        if old.isOptional, !new.isOptional, old.core == new.core {
            return .compatible(
                "the candidate nonoptional result can be promoted to the previous optional result"
            )
        }
        return .incompatible("the candidate result type is not source-compatible")
    }

    private static func effectCompatibility(
        baseline: SDKSymbol,
        candidate: SDKSymbol
    ) -> SDKSourceCompatibility {
        let oldDeclaration = baseline.declaration ?? baseline.signature ?? ""
        let newDeclaration = candidate.declaration ?? candidate.signature ?? ""
        let oldThrows = containsWord("throws", in: oldDeclaration)
            || containsWord("rethrows", in: oldDeclaration)
        let newThrows = containsWord("throws", in: newDeclaration)
            || containsWord("rethrows", in: newDeclaration)
        if !oldThrows, newThrows {
            return .incompatible("the candidate declaration newly requires error handling")
        }
        if !baseline.concurrency.isAsync, candidate.concurrency.isAsync {
            return .incompatible("the candidate declaration newly requires asynchronous use")
        }
        if baseline.concurrency.actorIsolation == nil,
           candidate.concurrency.actorIsolation != nil
        {
            return .uncertain("the candidate declaration adds actor isolation")
        }
        if !baseline.concurrency.isSendable, candidate.concurrency.isSendable {
            return .uncertain("the candidate declaration adds a Sendable restriction")
        }
        if !baseline.concurrency.isPreconcurrency,
           candidate.concurrency.isPreconcurrency
        {
            return .uncertain("the candidate declaration changes preconcurrency checking")
        }
        return .compatible("calling effects are not more restrictive")
    }

    private static func restrictionCompatibility(
        old: ParsedType,
        new: ParsedType
    ) -> Bool {
        if !old.attributes.contains("Sendable"),
           new.attributes.contains("Sendable")
        {
            return false
        }
        if !old.attributes.contains("isolated"),
           new.attributes.contains("isolated")
        {
            return false
        }
        if old.ownership != new.ownership,
           old.ownership != nil || new.ownership != nil
        {
            return false
        }
        return true
    }

    private static func parsedType(_ value: String) -> ParsedType {
        let optional = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .hasSuffix("?")
        let attributes = Set(
            ["Sendable", "escaping", "autoclosure", "isolated"].filter {
                value.range(
                    of: #"@\#($0)\b"#,
                    options: .regularExpression
                ) != nil
            }
        )
        let ownership = ["sending", "consuming", "borrowing", "inout"].first {
            containsWord($0, in: value)
        }
        var core = value
            .replacingOccurrences(
                of: #"@(Sendable|escaping|autoclosure|isolated(?:\([^)]*\))?)\s*"#,
                with: "",
                options: .regularExpression
            )
        for modifier in ["sending", "consuming", "borrowing", "inout"] {
            core = core.replacingOccurrences(
                of: #"\b\#(modifier)\b\s*"#,
                with: "",
                options: .regularExpression
            )
        }
        core = core
            .trimmingCharacters(in: CharacterSet(charactersIn: "? "))
            .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
        return ParsedType(
            core: core,
            isOptional: optional,
            attributes: attributes,
            ownership: ownership
        )
    }

    private static func normalizedLabel(_ value: String?) -> String {
        value ?? "_"
    }

    private static func isVariadic(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines)
            .hasSuffix("...") == true
    }

    private static func callableKind(_ symbol: SDKSymbol) -> String {
        let kind = symbol.kind.lowercased()
        if kind.contains("init") {
            return "initializer"
        }
        if kind.contains("subscript") {
            return "subscript"
        }
        if kind.contains("method") || kind.contains("func") {
            return "function"
        }
        return kind
    }

    private static func instanceDomain(_ symbol: SDKSymbol) -> String {
        let declaration = symbol.declaration ?? symbol.signature ?? ""
        if containsWord("static", in: declaration) {
            return "static"
        }
        if containsWord("class", in: declaration) {
            return "class"
        }
        return "instance"
    }

    private static func availabilityBecameMoreRestrictive(
        baseline: SDKSymbol,
        candidate: SDKSymbol,
        platform: String
    ) -> Bool {
        let old = SDKSnapshotDiffer.relevantAvailability(
            baseline.availability,
            platform: platform
        ).compactMap(\.introduced).min()
        let new = SDKSnapshotDiffer.relevantAvailability(
            candidate.availability,
            platform: platform
        ).compactMap(\.introduced).min()
        guard let new else { return false }
        guard let old else { return true }
        return compareVersions(new, old) == .orderedDescending
    }

    private static func compareVersions(
        _ lhs: String,
        _ rhs: String
    ) -> ComparisonResult {
        lhs.compare(rhs, options: .numeric)
    }

    private static func genericConstraintsStrengthened(
        baseline: String?,
        candidate: String?
    ) -> Bool {
        let old = normalizedWhereClause(baseline)
        let new = normalizedWhereClause(candidate)
        return old != new && !new.isEmpty
    }

    private static func normalizedWhereClause(_ value: String?) -> String {
        guard let value,
              let range = value.range(
                  of: #"\bwhere\b.*$"#,
                  options: .regularExpression
              )
        else {
            return ""
        }
        return value[range]
            .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
    }

    private static func containsWord(
        _ word: String,
        in value: String
    ) -> Bool {
        value.range(
            of: #"\b\#(word)\b"#,
            options: .regularExpression
        ) != nil
    }
}

private struct ParsedType {
    let core: String
    let isOptional: Bool
    let attributes: Set<String>
    let ownership: String?
}
