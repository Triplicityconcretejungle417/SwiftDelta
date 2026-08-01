//===--- XCResultReader.swift - SwiftDelta ------------------------------------------===//
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

public enum XCResultDiagnosticParser {
    public static func parse(_ data: Data) throws -> [CompilerDiagnostic] {
        let root = try JSONSerialization.jsonObject(with: data)
        var diagnostics: [CompilerDiagnostic] = []
        walk(root, inheritedSeverity: nil, diagnostics: &diagnostics)
        return CompilerDiagnosticParser.deduplicate(diagnostics)
    }

    private static func walk(
        _ value: Any,
        inheritedSeverity: Severity?,
        diagnostics: inout [CompilerDiagnostic]
    ) {
        if let dictionary = value as? [String: Any] {
            if let message = wrappedString(dictionary["message"]),
               dictionary["issueType"] != nil
                || dictionary["severity"] != nil
                || dictionary["documentLocationInCreatingWorkspace"] != nil
            {
                let issueType = wrappedString(dictionary["issueType"]) ?? ""
                let explicitSeverity = wrappedString(dictionary["severity"])
                    ?? wrappedString(dictionary["diagnosticSeverity"])
                let resolvedSeverity = explicitSeverity.flatMap(
                    recognizedSeverity
                ) ?? recognizedSeverity(issueType)
                    ?? inheritedSeverity
                    ?? .notice
                let locationURL = wrappedString(dictionary["sourceURL"])
                    ?? wrappedString(
                        (dictionary["documentLocationInCreatingWorkspace"] as? [String: Any])?["url"]
                    )
                diagnostics.append(
                    CompilerDiagnostic(
                        message: SecretRedactor.redact(message),
                        severity: resolvedSeverity,
                        location: locationURL.flatMap(parseLocation),
                        kind: diagnosticKind(issueType: issueType, message: message),
                        target: wrappedString(dictionary["targetName"])
                    )
                )
            }
            for (key, child) in dictionary {
                walk(
                    child,
                    inheritedSeverity: collectionSeverity(key)
                        ?? inheritedSeverity,
                    diagnostics: &diagnostics
                )
            }
        } else if let array = value as? [Any] {
            for child in array {
                walk(
                    child,
                    inheritedSeverity: inheritedSeverity,
                    diagnostics: &diagnostics
                )
            }
        }
    }

    private static func wrappedString(_ value: Any?) -> String? {
        if let value = value as? String {
            return value
        }
        if let dictionary = value as? [String: Any] {
            return dictionary["_value"] as? String
                ?? dictionary["value"] as? String
        }
        return nil
    }

    private static func parseLocation(_ value: String) -> SourceLocation? {
        guard let hash = value.firstIndex(of: "#") else {
            return SourceLocation(path: normalizedPath(from: value))
        }
        let base = String(value[..<hash])
        let fragment = String(value[value.index(after: hash)...])
        let values = fragment.split(separator: "&").reduce(into: [String: String]()) {
            result, pair in
            let components = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if components.count == 2 {
                result[components[0]] = components[1]
            }
        }
        return SourceLocation(
            path: normalizedPath(from: base),
            line: values["StartingLineNumber"].flatMap(Int.init),
            column: values["StartingColumnNumber"].flatMap(Int.init)
        )
    }

    private static func normalizedPath(from value: String) -> String {
        let path = URL(string: value)?.path ?? value
        guard NSString(string: path).isAbsolutePath else {
            return path
        }
        return URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private static func recognizedSeverity(_ source: String) -> Severity? {
        let value = source.lowercased()
        if value.contains("error") || value.contains("fatal") {
            return .error
        }
        if value.contains("warning") {
            return .warning
        }
        if value.contains("notice")
            || value.contains("note")
            || value.contains("remark")
        {
            return .notice
        }
        return nil
    }

    private static func collectionSeverity(_ key: String) -> Severity? {
        let normalized = key.lowercased()
        if normalized.contains("error") || normalized.contains("fatal") {
            return .error
        }
        if normalized.contains("warning") {
            return .warning
        }
        if normalized.contains("notice")
            || normalized.contains("note")
            || normalized.contains("remark")
        {
            return .notice
        }
        return nil
    }

    private static func diagnosticKind(
        issueType: String,
        message: String
    ) -> CompilerDiagnosticKind {
        let combined = "\(issueType) \(message)".lowercased()
        if combined.contains("linker") {
            return .linker
        }
        if combined.contains("package") || combined.contains("dependency") {
            return .package
        }
        if combined.contains("build phase") || combined.contains("script") {
            return .buildPhase
        }
        if combined.contains("module") {
            return .module
        }
        return .compiler
    }
}

public enum XCResultReadStrategy: String, Codable, Sendable {
    case modernStructured
    case legacyStructured
    case unavailable
}

public struct XCResultReadOutcome: Sendable {
    public let diagnostics: [CompilerDiagnostic]
    public let strategy: XCResultReadStrategy

    public init(
        diagnostics: [CompilerDiagnostic],
        strategy: XCResultReadStrategy
    ) {
        self.diagnostics = diagnostics
        self.strategy = strategy
    }
}

/// Reads diagnostics using the xcresulttool interface supplied by one selected
/// Xcode installation.
///
/// The fallback order is modern structured output, legacy structured output,
/// then an unavailable result that lets the build layer parse xcodebuild text.
public struct XCResultReader: Sendable {
    private let runner: any ProcessRunning

    public init(runner: any ProcessRunning = ProcessRunner()) {
        self.runner = runner
    }

    public func readDiagnostics(
        bundleURL: URL,
        developerDirectory: String,
        timeout: TimeInterval = 30
    ) -> [CompilerDiagnostic] {
        read(
            bundleURL: bundleURL,
            developerDirectory: developerDirectory,
            timeout: timeout
        ).diagnostics
    }

    public func read(
        bundleURL: URL,
        developerDirectory: String,
        timeout: TimeInterval = 30
    ) -> XCResultReadOutcome {
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            return XCResultReadOutcome(diagnostics: [], strategy: .unavailable)
        }
        if supportsModernBuildResults(
            developerDirectory: developerDirectory,
            workingDirectory: bundleURL.deletingLastPathComponent(),
            timeout: timeout
        ) {
            let arguments = [
                "xcresulttool", "get", "build-results",
                "--path", bundleURL.path, "--compact",
            ]
            if let diagnostics = runStructuredCommand(
                arguments,
                bundleURL: bundleURL,
                developerDirectory: developerDirectory,
                timeout: timeout
            ) {
                return XCResultReadOutcome(
                    diagnostics: diagnostics,
                    strategy: .modernStructured
                )
            }
        }
        let legacyCommands = [
            [
                "xcresulttool", "get", "object", "--legacy",
                "--path", bundleURL.path, "--format", "json",
            ],
            ["xcresulttool", "get", "--legacy", "--path", bundleURL.path, "--format", "json"],
        ]
        for arguments in legacyCommands {
            if let diagnostics = runStructuredCommand(
                arguments,
                bundleURL: bundleURL,
                developerDirectory: developerDirectory,
                timeout: timeout
            ) {
                return XCResultReadOutcome(
                    diagnostics: diagnostics,
                    strategy: .legacyStructured
                )
            }
        }
        return XCResultReadOutcome(diagnostics: [], strategy: .unavailable)
    }

    private func runStructuredCommand(
        _ arguments: [String],
        bundleURL: URL,
        developerDirectory: String,
        timeout: TimeInterval
    ) -> [CompilerDiagnostic]? {
        guard let result = try? runner.run(
            executable: "/usr/bin/xcrun",
            arguments: arguments,
            environment: ["DEVELOPER_DIR": developerDirectory],
            workingDirectory: bundleURL.deletingLastPathComponent(),
            timeout: timeout,
            cancellation: { false }
        ), result.exitStatus == 0 else {
            return nil
        }
        return try? XCResultDiagnosticParser.parse(result.standardOutput)
    }

    private func supportsModernBuildResults(
        developerDirectory: String,
        workingDirectory: URL,
        timeout: TimeInterval
    ) -> Bool {
        guard let result = try? runner.run(
            executable: "/usr/bin/xcrun",
            arguments: ["xcresulttool", "help", "get", "build-results"],
            environment: ["DEVELOPER_DIR": developerDirectory],
            workingDirectory: workingDirectory,
            timeout: timeout,
            cancellation: { false }
        ), result.exitStatus == 0 else {
            return false
        }
        let output = result.standardOutputString + result.standardErrorString
        return output.contains("get build-results")
            || output.contains("high level description of build action")
    }
}
