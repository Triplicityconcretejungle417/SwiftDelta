//===--- DiagnosticComparison.swift - SwiftDelta ------------------------------------------===//
//
// This source file is part of the SwiftDelta open source project
//
// Copyright (c) 2026 Jiaxu Li
// Licensed under the Apache License, Version 2.0
//
// See LICENSE for license information
//
//===----------------------------------------------------------------------===//

import CryptoKit
import Foundation

public enum DiagnosticComparator {
    public static func introduced(
        old: [CompilerDiagnostic],
        new: [CompilerDiagnostic]
    ) -> [CompilerDiagnostic] {
        let previous = Dictionary(
            grouping: CompilerDiagnosticParser.deduplicate(old),
            by: \.deduplicationKey
        )
        return CompilerDiagnosticParser.deduplicate(
            new.filter { candidate in
                guard let baseline = previous[candidate.deduplicationKey],
                      let strongestBaseline = baseline.max(by: {
                        $0.severity.rank < $1.severity.rank
                      })
                else {
                    return true
                }
                // Severity transitions are directional. Only a stronger
                // candidate classification is a regression.
                return candidate.severity.rank > strongestBaseline.severity.rank
            }
        )
    }
}

public enum CompilerFindingAdapter {
    public static func findings(
        from diagnostics: [CompilerDiagnostic],
        targetVersion: String?
    ) -> [Finding] {
        diagnostics.map { diagnostic in
            Finding(
                findingID: findingIdentifier(for: diagnostic),
                category: category(for: diagnostic.kind),
                title: title(for: diagnostic),
                explanation: diagnostic.message,
                severity: diagnostic.severity,
                confidence: .high,
                location: diagnostic.location,
                targetVersion: targetVersion,
                origin: .compiler,
                target: diagnostic.target,
                identityDiscriminator: diagnostic.diagnosticID
            )
        }
    }

    private static func findingIdentifier(
        for diagnostic: CompilerDiagnostic
    ) -> String {
        let base = "compiler.\(diagnostic.kind.rawValue)"
        guard let identity = diagnostic.diagnosticID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !identity.isEmpty
        else {
            return base
        }
        let digest = SHA256.hash(data: Data(identity.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(base).\(digest)"
    }

    private static func category(for kind: CompilerDiagnosticKind) -> FindingCategory {
        switch kind {
        case .package: .dependency
        case .compiler, .linker, .module, .buildPhase, .unknown: .compiler
        }
    }

    private static func title(for diagnostic: CompilerDiagnostic) -> String {
        switch diagnostic.kind {
        case .compiler: "New compiler diagnostic"
        case .linker: "New linker diagnostic"
        case .module: "New module diagnostic"
        case .package: "New package diagnostic"
        case .buildPhase: "New Build Phase diagnostic"
        case .unknown: "New build diagnostic"
        }
    }

}
