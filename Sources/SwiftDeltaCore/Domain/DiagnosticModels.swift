//===--- DiagnosticModels.swift - SwiftDelta ------------------------------------------===//
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

public enum CompilerDiagnosticKind: String, Codable, Sendable {
    case compiler
    case linker
    case module
    case package
    case buildPhase
    case unknown
}

public struct CompilerDiagnostic: Codable, Hashable, Sendable {
    public let message: String
    public let severity: Severity
    public let location: SourceLocation?
    public let kind: CompilerDiagnosticKind
    public let target: String?
    public let diagnosticID: String?

    public init(
        message: String,
        severity: Severity,
        location: SourceLocation? = nil,
        kind: CompilerDiagnosticKind = .compiler,
        target: String? = nil,
        diagnosticID: String? = nil
    ) {
        self.message = message
        self.severity = severity
        self.location = location
        self.kind = kind
        self.target = target
        self.diagnosticID = diagnosticID
    }

    public var normalizedKey: String {
        diagnosticKey(includeSeverity: true)
    }

    var deduplicationKey: String {
        diagnosticKey(includeSeverity: false)
    }

    private func diagnosticKey(includeSeverity: Bool) -> String {
        var normalizedMessage = message
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "‘", with: "")
            .replacingOccurrences(of: "’", with: "")
            .replacingOccurrences(of: "“", with: "")
            .replacingOccurrences(of: "”", with: "")
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        while normalizedMessage.last == "." || normalizedMessage.last == ":" {
            normalizedMessage.removeLast()
        }
        let stableIdentity = diagnosticID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            stableIdentity ?? "",
            kind.rawValue,
            includeSeverity ? severity.rawValue : "",
            normalizedDiagnosticPath(location?.path ?? ""),
            location?.line.map(String.init) ?? "",
            location?.column.map(String.init) ?? "",
            target ?? "",
            stableIdentity?.isEmpty == false ? "" : normalizedMessage,
        ].joined(separator: "|")
    }

    private func normalizedDiagnosticPath(_ path: String) -> String {
        let markers = [
            "/Build/Intermediates.noindex/",
            "/Build/Products/",
            "/SourcePackages/",
            "/plugins/outputs/",
        ]
        for marker in markers {
            if let range = path.range(of: marker) {
                return "<generated>" + path[range.lowerBound...]
            }
        }
        return path
    }
}

public struct BuildSettingsSnapshot: Codable, Equatable, Sendable {
    public let target: String?
    public let configuration: String?
    public let settings: [String: String]

    public init(
        target: String? = nil,
        configuration: String? = nil,
        settings: [String: String]
    ) {
        self.target = target
        self.configuration = configuration
        self.settings = settings
    }
}
