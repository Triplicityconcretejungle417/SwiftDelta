//===--- SDKInterfaceScanner.swift - SwiftDelta ------------------------------------------===//
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

public enum SDKInterfaceScanner {
    public static func scan(module: String, sdkPath: String) throws -> [SDKSymbol] {
        let moduleDirectory = URL(fileURLWithPath: sdkPath)
            .appendingPathComponent("System/Library/Frameworks", isDirectory: true)
            .appendingPathComponent("\(module).framework", isDirectory: true)
            .appendingPathComponent("Modules/\(module).swiftmodule", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: moduleDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ), let interface = files
            .filter({ $0.pathExtension == "swiftinterface" })
            .sorted(by: { $0.path < $1.path })
            .first
        else {
            return []
        }
        let data = try Data(contentsOf: interface, options: [.mappedIfSafe])
        let source = String(decoding: data, as: UTF8.self)
        var availability: [SDKAvailability] = []
        var symbols: [SDKSymbol] = []
        for rawLine in source.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("@available(") {
                availability = parseAvailability(line)
                continue
            }
            guard line.hasPrefix("public ") || line.hasPrefix("open ") else {
                if !line.hasPrefix("@") {
                    availability = []
                }
                continue
            }
            guard let declaration = line.split(separator: "{", maxSplits: 1).first.map(String.init),
                  let parsed = declarationIdentity(declaration)
            else {
                availability = []
                continue
            }
            let qualified = "\(module).\(parsed.name)"
            symbols.append(
                SDKSymbol(
                    id: "swiftinterface|\(module)|\(parsed.kind)|\(declaration)",
                    moduleName: module,
                    fullyQualifiedName: qualified,
                    baseName: parsed.name.split(separator: "(").first.map(String.init) ?? parsed.name,
                    kind: parsed.kind,
                    declaration: declaration,
                    signature: declaration,
                    availability: availability,
                    isUnavailable: availability.contains {
                        $0.isUnconditionallyUnavailable
                    },
                    renamedDestination: availability.compactMap(\.renamed).first,
                    migrationMessage: availability.compactMap(\.message).first,
                    concurrency: SDKConcurrencyMetadata(
                        actorIsolation: declaration.contains("@MainActor") ? "MainActor" : nil,
                        isAsync: declaration.contains(" async"),
                        isSendable: declaration.contains("Sendable"),
                        isNonisolated: declaration.contains("nonisolated"),
                        isPreconcurrency: declaration.contains("@preconcurrency")
                    )
                )
            )
            availability = []
        }
        return symbols
    }

    private static func declarationIdentity(_ declaration: String) -> (kind: String, name: String)? {
        let patterns: [(String, String)] = [
            (#"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?)"#, "swift.func"),
            (#"\b(?:var|let)\s+([A-Za-z_][A-Za-z0-9_]*)"#, "swift.var"),
            (#"\bclass\s+([A-Za-z_][A-Za-z0-9_]*)"#, "swift.class"),
            (#"\bstruct\s+([A-Za-z_][A-Za-z0-9_]*)"#, "swift.struct"),
            (#"\benum\s+([A-Za-z_][A-Za-z0-9_]*)"#, "swift.enum"),
            (#"\bprotocol\s+([A-Za-z_][A-Za-z0-9_]*)"#, "swift.protocol"),
            (#"\btypealias\s+([A-Za-z_][A-Za-z0-9_]*)"#, "swift.typealias"),
        ]
        for (pattern, kind) in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else {
                continue
            }
            let range = NSRange(declaration.startIndex..<declaration.endIndex, in: declaration)
            guard let match = expression.firstMatch(in: declaration, range: range),
                  let nameRange = Range(match.range(at: 1), in: declaration)
            else {
                continue
            }
            return (kind, String(declaration[nameRange]))
        }
        return nil
    }

    private static func parseAvailability(_ declaration: String) -> [SDKAvailability] {
        let contents = declaration
            .replacingOccurrences(of: "@available(", with: "")
            .split(separator: ")", maxSplits: 1)
            .first
            .map(String.init) ?? ""
        let components = contents.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard let domain = components.first, !domain.isEmpty else {
            return []
        }
        var introduced: String?
        var deprecated: String?
        var obsoleted: String?
        var renamed: String?
        var message: String?
        var unavailable = false
        for component in components.dropFirst() {
            if component == "unavailable" {
                unavailable = true
            } else if component.hasPrefix("introduced:") {
                introduced = value(after: "introduced:", in: component)
            } else if component.hasPrefix("deprecated:") {
                deprecated = value(after: "deprecated:", in: component)
            } else if component.hasPrefix("obsoleted:") {
                obsoleted = value(after: "obsoleted:", in: component)
            } else if component.hasPrefix("renamed:") {
                renamed = unquote(value(after: "renamed:", in: component))
            } else if component.hasPrefix("message:") {
                message = unquote(value(after: "message:", in: component))
            }
        }
        return [
            SDKAvailability(
                domain: domain,
                introduced: introduced,
                deprecated: deprecated,
                obsoleted: obsoleted,
                isUnconditionallyUnavailable: unavailable,
                renamed: renamed,
                message: message
            ),
        ]
    }

    private static func value(after prefix: String, in value: String) -> String {
        String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    private static func unquote(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }
}
