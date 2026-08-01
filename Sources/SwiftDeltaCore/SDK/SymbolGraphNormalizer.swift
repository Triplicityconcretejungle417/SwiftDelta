//===--- SymbolGraphNormalizer.swift - SwiftDelta ------------------------------------------===//
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

public enum SymbolGraphNormalizer {
    public static func normalize(
        _ graphData: [Data],
        requestedModule: String? = nil
    ) throws -> [SDKSymbol] {
        var rawSymbols: [[String: Any]] = []
        var relationships: [[String: Any]] = []
        for data in graphData {
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                continue
            }
            let module = ((root["module"] as? [String: Any])?["name"] as? String)
                ?? requestedModule
                ?? "Unknown"
            for var symbol in root["symbols"] as? [[String: Any]] ?? [] {
                symbol["_normalizedModule"] = module
                rawSymbols.append(symbol)
            }
            relationships.append(contentsOf: root["relationships"] as? [[String: Any]] ?? [])
        }

        let relationshipsBySource = Dictionary(
            grouping: relationships.compactMap { relationship -> SDKSymbolRelationshipRecord? in
                guard let source = relationship["source"] as? String,
                      let kind = relationship["kind"] as? String,
                      let target = relationship["target"] as? String
                else {
                    return nil
                }
                return SDKSymbolRelationshipRecord(
                    source: source,
                    relationship: SDKSymbolRelationship(kind: kind, target: target)
                )
            },
            by: \.source
        )

        let symbols = rawSymbols.compactMap { raw -> SDKSymbol? in
            guard let module = raw["_normalizedModule"] as? String,
                  let kind = (raw["kind"] as? [String: Any])?["identifier"] as? String,
                  let pathComponents = raw["pathComponents"] as? [String],
                  !pathComponents.isEmpty
            else {
                return nil
            }
            let identifier = (raw["identifier"] as? [String: Any])?["precise"] as? String
            let names = raw["names"] as? [String: Any]
            let title = names?["title"] as? String ?? pathComponents.last ?? "unknown"
            let baseName = title.split(separator: "(").first.map(String.init) ?? title
            let qualified = ([module] + pathComponents).joined(separator: ".")
            let declaration = fragmentsText(raw["declarationFragments"])
                ?? fragmentsText(names?["subHeading"])
            let functionSignature = raw["functionSignature"] as? [String: Any]
            let parameters = (functionSignature?["parameters"] as? [[String: Any]] ?? []).map {
                parameter in
                let declaration = fragmentsText(parameter["declarationFragments"])
                return SDKFunctionParameter(
                    name: parameter["internalName"] as? String ?? parameter["name"] as? String,
                    externalName: parameter["name"] as? String,
                    type: declaration.flatMap(typePortion),
                    hasDefaultValue: hasDefaultValue(
                        parameter: parameter,
                        declaration: declaration
                    )
                )
            }
            let returnType = fragmentsText(functionSignature?["returns"])
            let availability = Array(
                Set(
                    (raw["availability"] as? [[String: Any]] ?? [])
                        .compactMap(parseAvailability)
                )
            ).sorted {
                ($0.domain, $0.description) < ($1.domain, $1.description)
            }
            let unavailable = availability.contains {
                $0.isUnconditionallyUnavailable
            }
            let renamed = availability.compactMap(\.renamed).first
            let message = availability.compactMap(\.message).first
            let concurrency = concurrencyMetadata(declaration ?? "")
            let access = propertyAccess(declaration: declaration, kind: kind)
            let symbolRelationships = relationshipsBySource[identifier ?? ""]?
                .map(\.relationship)
                .reduce(into: Set<SDKSymbolRelationship>()) {
                    $0.insert($1)
                }
                .sorted { ($0.kind, $0.target) < ($1.kind, $1.target) } ?? []
            let isRequirement = symbolRelationships.contains {
                $0.kind == "requirementOf" || $0.kind == "optionalRequirementOf"
            }
            let fallbackID = [
                "symbolgraph",
                module,
                qualified,
                kind,
                declaration ?? "",
            ].joined(separator: "|")
            return SDKSymbol(
                id: identifier ?? fallbackID,
                moduleName: module,
                preciseIdentifier: identifier,
                fullyQualifiedName: qualified,
                baseName: baseName,
                kind: kind,
                declaration: declaration,
                signature: fragmentsText(names?["subHeading"]) ?? declaration,
                parameters: parameters,
                returnType: returnType,
                availability: availability,
                isUnavailable: unavailable,
                renamedDestination: renamed,
                migrationMessage: message,
                concurrency: concurrency,
                relationships: symbolRelationships,
                propertyReadable: access.readable,
                propertyWritable: access.writable,
                isProtocolRequirement: isRequirement
            )
        }
        // Symbol Graph extraction can emit the same declaration in multiple
        // files. Exact duplicates are one evidence record; non-identical
        // declarations sharing an identity remain visible for conservative
        // ambiguity handling in the differ.
        return Array(Set(symbols)).sorted {
            ($0.moduleName, $0.fullyQualifiedName, $0.id)
                < ($1.moduleName, $1.fullyQualifiedName, $1.id)
        }
    }

    private static func fragmentsText(_ value: Any?) -> String? {
        guard let fragments = value as? [[String: Any]] else {
            return nil
        }
        let text = fragments.compactMap { $0["spelling"] as? String }.joined()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return text.isEmpty ? nil : text
    }

    private static func typePortion(_ declaration: String) -> String? {
        guard let colon = declaration.firstIndex(of: ":") else {
            return nil
        }
        let value = declaration[declaration.index(after: colon)...]
        let type = value.split(separator: "=", maxSplits: 1).first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return type.isEmpty ? nil : type
    }

    private static func hasDefaultValue(
        parameter: [String: Any],
        declaration: String?
    ) -> Bool? {
        if let value = parameter["hasDefaultValue"] as? Bool {
            return value
        }
        if parameter["defaultValue"] != nil {
            return true
        }
        guard let declaration else {
            return nil
        }
        return declaration.contains("=") ? true : false
    }

    private static func parseAvailability(_ value: [String: Any]) -> SDKAvailability? {
        guard let domain = value["domain"] as? String else {
            return nil
        }
        return SDKAvailability(
            domain: domain,
            introduced: versionText(value["introduced"]),
            deprecated: versionText(value["deprecated"]),
            obsoleted: versionText(value["obsoleted"]),
            isUnconditionallyDeprecated: value["isUnconditionallyDeprecated"] as? Bool ?? false,
            isUnconditionallyUnavailable: value["isUnconditionallyUnavailable"] as? Bool ?? false,
            renamed: value["renamed"] as? String,
            message: value["message"] as? String
        )
    }

    private static func versionText(_ value: Any?) -> String? {
        if let text = value as? String {
            return text
        }
        guard let components = value as? [String: Any],
              let major = components["major"] as? Int
        else {
            return nil
        }
        var values = [major]
        if let minor = components["minor"] as? Int {
            values.append(minor)
        }
        if let patch = components["patch"] as? Int {
            values.append(patch)
        }
        return values.map(String.init).joined(separator: ".")
    }

    private static func concurrencyMetadata(_ declaration: String) -> SDKConcurrencyMetadata {
        let words = declaration.split {
            !$0.isLetter && !$0.isNumber && $0 != "_"
        }
        return SDKConcurrencyMetadata(
            actorIsolation: actorIsolation(in: declaration),
            isAsync: words.contains("async"),
            isSendable: words.contains("Sendable"),
            isNonisolated: words.contains("nonisolated"),
            isPreconcurrency: declaration.contains("@preconcurrency")
        )
    }

    private static func actorIsolation(in declaration: String) -> String? {
        var searchStart = declaration.startIndex
        while let marker = declaration[searchStart...].firstIndex(of: "@") {
            let start = declaration.index(after: marker)
            var end = start
            while end < declaration.endIndex {
                let character = declaration[end]
                guard character.isLetter
                    || character.isNumber
                    || character == "_"
                else {
                    break
                }
                end = declaration.index(after: end)
            }
            if start < end {
                let identifier = declaration[start..<end]
                if (identifier.first?.isLetter == true
                    || identifier.first == "_"),
                    identifier.hasSuffix("Actor")
                {
                    return String(identifier)
                }
            }
            searchStart = end > marker
                ? end
                : declaration.index(after: marker)
        }
        return nil
    }

    private static func propertyAccess(
        declaration: String?,
        kind: String
    ) -> (readable: Bool?, writable: Bool?) {
        guard kind.contains("property") || kind.contains("var"),
              let declaration
        else {
            return (nil, nil)
        }
        if declaration.contains("{ get set }") || declaration.contains("{ get async set }") {
            return (true, true)
        }
        if declaration.contains("{ get") {
            return (true, false)
        }
        if declaration.contains(" let ") || declaration.hasPrefix("let ") {
            return (true, false)
        }
        return (true, true)
    }
}

private struct SDKSymbolRelationshipRecord {
    let source: String
    let relationship: SDKSymbolRelationship
}
