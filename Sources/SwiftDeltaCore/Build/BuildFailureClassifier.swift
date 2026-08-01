//===--- BuildFailureClassifier.swift - SwiftDelta ------------------------------------------===//
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

enum BuildFailureClassifier {
    // Setup failures stay separate from source compatibility findings.
    private static let environmentSummaries = [
        "Destination selection failed",
        "The requested SDK is unavailable",
        "Code signing configuration failed",
        "Package dependency resolution failed",
        "xcodebuild could not satisfy the selected build environment",
    ]

    static func diagnostic(
        status: Int32,
        log: String,
        invocation: BuildInvocation
    ) -> CompilerDiagnostic? {
        guard status != 0 else { return nil }
        let lower = log.lowercased()
        let classification: (summary: String, markers: [String], kind: CompilerDiagnosticKind)

        if lower.contains("unable to find a destination")
            || lower.contains("ineligible destinations")
            || lower.contains("platform is not installed")
            || lower.contains("platform support") && lower.contains("not installed")
        {
            classification = (
                "Destination selection failed",
                [
                    "unable to find a destination",
                    "ineligible destinations",
                    "not installed",
                    "platform support",
                ],
                .buildPhase
            )
        } else if lower.contains("unable to find sdk")
                    || lower.contains("sdk") && lower.contains("cannot be located")
                    || lower.contains("sdk is not installed")
                    || lower.contains("sdk") && lower.contains("does not exist")
        {
            classification = (
                "The requested SDK is unavailable",
                ["unable to find sdk", "cannot be located", "not installed", "does not exist"],
                .module
            )
        } else if lower.contains("requires a provisioning profile")
                    || lower.contains("code signing")
                    || lower.contains("signing for")
        {
            classification = (
                "Code signing configuration failed",
                ["provisioning profile", "code signing", "signing for"],
                .buildPhase
            )
        } else if lower.contains("package resolution")
                    || lower.contains("could not resolve package dependencies")
                    || lower.contains("failed to clone")
        {
            classification = (
                "Package dependency resolution failed",
                ["could not resolve package dependencies", "package resolution", "failed to clone"],
                .package
            )
        } else if lower.contains("actool")
                    || lower.contains("asset catalog")
                    || lower.contains("compileassetcatalog")
        {
            classification = (
                "Asset compilation failed",
                ["asset catalog", "compileassetcatalog", "actool"],
                .buildPhase
            )
        } else if lower.contains("swiftcompile")
                    || lower.contains("swift compiler error")
        {
            classification = (
                "Swift compilation failed",
                ["swift compiler error", "swiftcompile"],
                .compiler
            )
        } else if status == 70 {
            classification = (
                "xcodebuild could not satisfy the selected build environment",
                ["error:", "failed"],
                .buildPhase
            )
        } else {
            return nil
        }

        let detail = conciseDetail(log, markers: classification.markers)
        let identity = invocation.xcodeIdentity
            ?? URL(fileURLWithPath: invocation.xcodePath).lastPathComponent
        let container = URL(fileURLWithPath: invocation.container.path).lastPathComponent
        let sdk = invocation.sdkIdentifiers.isEmpty
            ? "<build setting>"
            : invocation.sdkIdentifiers.joined(separator: ", ")
        let destination = invocation.destination ?? "<default>"
        var message =
            "\(classification.summary) with \(identity) for \(container), "
            + "scheme \(invocation.scheme.isEmpty ? "<package>" : invocation.scheme), "
            + "SDK \(sdk), destination \(destination)."
        if let detail, !detail.isEmpty {
            message += " \(detail)"
        }
        return CompilerDiagnostic(
            message: SecretRedactor.redact(message),
            severity: .error,
            kind: classification.kind
        )
    }

    static func isEnvironmentFailure(_ diagnostic: CompilerDiagnostic) -> Bool {
        environmentSummaries.contains {
            diagnostic.message.hasPrefix($0)
        }
    }

    private static func conciseDetail(
        _ log: String,
        markers: [String]
    ) -> String? {
        let lines = log.split(whereSeparator: \.isNewline).map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let explicitError = lines.first {
            let lower = $0.lowercased()
            return lower.hasPrefix("error:") || lower.contains(": error:")
        }
        guard let line = explicitError ?? lines.first(where: { line in
            let lower = line.lowercased()
            return markers.contains { lower.contains($0) }
        }) else {
            return nil
        }
        let redacted = SecretRedactor.redact(line)
        if redacted.count <= 500 {
            return redacted
        }
        return String(redacted.prefix(497)) + "..."
    }
}
