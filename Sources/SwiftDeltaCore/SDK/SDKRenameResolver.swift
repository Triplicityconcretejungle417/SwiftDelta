//===--- SDKRenameResolver.swift - SwiftDelta ------------------------------------------===//
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

/// Resolves an SDK-provided Swift rename destination against one normalized
/// candidate snapshot. A result is returned only when the destination describes
/// exactly one stable candidate symbol in the same module.
enum SDKRenameResolver {
    static func uniqueDestination(
        for source: SDKSymbol,
        destination: String,
        in symbols: [SDKSymbol]
    ) -> SDKSymbol? {
        let parsed = ParsedDestination(
            destination,
            module: source.moduleName
        )
        guard !parsed.baseName.isEmpty else { return nil }
        let sourceParent = parentPath(
            source.fullyQualifiedName,
            module: source.moduleName
        )
        let matches = symbols.filter { candidate in
            guard candidate.moduleName == source.moduleName,
                  candidate.preciseIdentifier?.isEmpty == false,
                  sourceTokenName(candidate.baseName) == parsed.baseName,
                  kindFamily(candidate.kind) == kindFamily(source.kind)
            else {
                return false
            }
            let candidateParent = parentPath(
                candidate.fullyQualifiedName,
                module: candidate.moduleName
            )
            if parsed.parentPath.isEmpty {
                // A bare destination such as `schemaName` is relative to the
                // source declaration's owner, not every identically named
                // property in the module.
                guard sourceParent.isEmpty
                        || candidateParent == sourceParent
                else { return false }
            } else {
                guard parentMatches(
                    candidateParent,
                    destinationParent: parsed.parentPath
                ) else { return false }
            }
            if let labels = parsed.parameterLabels {
                guard candidate.parameters.map(normalizedLabel) == labels else {
                    return false
                }
            }
            return true
        }
        let byStableIdentity = Dictionary(
            grouping: matches,
            by: { $0.preciseIdentifier! }
        )
        guard byStableIdentity.count == 1,
              let duplicates = byStableIdentity.values.first,
              let first = duplicates.first,
              duplicates.allSatisfy({
                  $0.fullyQualifiedName == first.fullyQualifiedName
                      && $0.declaration == first.declaration
              })
        else {
            return nil
        }
        return first
    }

    /// A token-only repair is valid only when the SDK rename keeps the symbol
    /// on the same owning declaration. A destination on another property or
    /// type needs a structural migration rather than an identifier swap.
    static func isIdentifierOnlyRename(
        from source: SDKSymbol,
        to destination: SDKSymbol
    ) -> Bool {
        parentPath(
            source.fullyQualifiedName,
            module: source.moduleName
        ) == parentPath(
            destination.fullyQualifiedName,
            module: destination.moduleName
        )
    }

    static func sourceTokenName(_ baseName: String) -> String {
        let head = baseName
            .split(separator: "(", maxSplits: 1)
            .first
            .map(String.init) ?? baseName
        return head.split(separator: ".").last.map(String.init) ?? head
    }

    static func destination(
        for symbol: SDKSymbol
    ) -> String? {
        symbol.renamedDestination
            ?? symbol.availability.compactMap(\.renamed).first
    }

    private static func normalizedLabel(
        _ parameter: SDKFunctionParameter
    ) -> String {
        parameter.externalName ?? "_"
    }

    private static func parentPath(
        _ fullyQualifiedName: String,
        module: String
    ) -> String {
        let head = fullyQualifiedName
            .split(separator: "(", maxSplits: 1)
            .first
            .map(String.init) ?? fullyQualifiedName
        var components = head.split(separator: ".").map(String.init)
        if components.first == module {
            components.removeFirst()
        }
        if !components.isEmpty {
            components.removeLast()
        }
        return components.joined(separator: ".")
    }

    private static func parentMatches(
        _ candidate: String,
        destinationParent: String
    ) -> Bool {
        if candidate == destinationParent
            || candidate.hasSuffix(".\(destinationParent)")
        {
            return true
        }
        // Swift importer rename metadata can express a property path while
        // the symbol graph records the property's value type as the owner.
        // Accept that spelling only when its final component is identical
        // after case folding; stable-identity uniqueness is still required.
        let candidateTail = candidate.split(separator: ".").last
            .map(String.init) ?? candidate
        let destinationTail = destinationParent.split(separator: ".").last
            .map(String.init) ?? destinationParent
        return candidateTail.caseInsensitiveCompare(destinationTail)
            == .orderedSame
    }

    private static func kindFamily(_ kind: String) -> String {
        if kind.contains("method") || kind.contains("func") {
            return "function"
        }
        if kind.contains("property") || kind.contains("var") {
            return "property"
        }
        if kind.contains("init") {
            return "initializer"
        }
        if kind.contains("subscript") {
            return "subscript"
        }
        return kind
    }

    private struct ParsedDestination {
        let baseName: String
        let parentPath: String
        let parameterLabels: [String]?

        init(_ value: String, module: String) {
            let trimmed = value.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let head = trimmed
                .split(separator: "(", maxSplits: 1)
                .first
                .map(String.init) ?? trimmed
            var components = head.split(separator: ".").map(String.init)
            if components.first == module {
                components.removeFirst()
            }
            baseName = components.last ?? ""
            parentPath = components.dropLast().joined(separator: ".")
            guard let open = trimmed.firstIndex(of: "("),
                  let close = trimmed.lastIndex(of: ")"),
                  open < close
            else {
                parameterLabels = nil
                return
            }
            let contents = trimmed[
                trimmed.index(after: open)..<close
            ]
            if contents.isEmpty {
                parameterLabels = []
                return
            }
            let labels = contents.split(
                separator: ":",
                omittingEmptySubsequences: false
            ).dropLast().map { component -> String in
                let token = component.split(separator: ",").last
                    .map(String.init) ?? String(component)
                return token.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            }
            parameterLabels = labels
        }
    }
}
