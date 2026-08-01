//===--- CompilerDiagnosticParser.swift - SwiftDelta ------------------------------------------===//
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

public enum CompilerDiagnosticParser {
    public static func parse(
        _ text: String,
        projectRoot: URL? = nil
    ) -> [CompilerDiagnostic] {
        let expressions = [
            try? NSRegularExpression(
                pattern: #"^(.+?):([0-9]+):([0-9]+):\s*(error|warning|note|remark):\s*(.+)$"#
            ),
            try? NSRegularExpression(
                pattern: #"^(.+?):([0-9]+):\s*(error|warning|note|remark):\s*(.+)$"#
            ),
        ].compactMap { $0 }

        var diagnostics: [CompilerDiagnostic] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = SecretRedactor.redact(String(rawLine))
            let fullRange = NSRange(line.startIndex..<line.endIndex, in: line)
            var matched = false

            for (index, expression) in expressions.enumerated() {
                guard let match = expression.firstMatch(in: line, range: fullRange) else {
                    continue
                }
                let path = capture(match, group: 1, in: line)
                let lineNumber = capture(match, group: 2, in: line).flatMap(Int.init)
                let columnNumber = index == 0
                    ? capture(match, group: 3, in: line).flatMap(Int.init)
                    : nil
                let severityGroup = index == 0 ? 4 : 3
                let messageGroup = index == 0 ? 5 : 4
                guard let severityText = capture(match, group: severityGroup, in: line),
                      let message = capture(match, group: messageGroup, in: line)
                else {
                    continue
                }
                let location = path.map {
                    SourceLocation(
                        path: normalizedPath($0, projectRoot: projectRoot),
                        line: lineNumber,
                        column: columnNumber
                    )
                }
                diagnostics.append(
                    CompilerDiagnostic(
                        message: message,
                        severity: severity(for: severityText),
                        location: location,
                        kind: kind(for: message)
                    )
                )
                matched = true
                break
            }

            if !matched, let diagnostic = progressDiagnostic(
                from: line,
                projectRoot: projectRoot
            ) ?? unlocatedDiagnostic(from: line) {
                diagnostics.append(diagnostic)
            }
        }
        return deduplicate(diagnostics)
    }

    private static func progressDiagnostic(
        from line: String,
        projectRoot: URL?
    ) -> CompilerDiagnostic? {
        guard let expression = try? NSRegularExpression(
            pattern: #"^(error|warning|note|remark):\s*(.+):([0-9]+):([0-9]+)\s+(.+)$"#
        ) else {
            return nil
        }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = expression.firstMatch(in: line, range: range),
              let severityText = capture(match, group: 1, in: line),
              let path = capture(match, group: 2, in: line),
              let lineNumber = capture(match, group: 3, in: line).flatMap(Int.init),
              let columnNumber = capture(match, group: 4, in: line).flatMap(Int.init),
              let message = capture(match, group: 5, in: line)
        else {
            return nil
        }
        return CompilerDiagnostic(
            message: message,
            severity: severity(for: severityText),
            location: SourceLocation(
                path: normalizedPath(path, projectRoot: projectRoot),
                line: lineNumber,
                column: columnNumber
            ),
            kind: kind(for: message)
        )
    }

    public static func deduplicate(
        _ diagnostics: [CompilerDiagnostic]
    ) -> [CompilerDiagnostic] {
        var values: [String: CompilerDiagnostic] = [:]
        for diagnostic in diagnostics {
            let key = diagnostic.deduplicationKey
            guard let existing = values[key] else {
                values[key] = diagnostic
                continue
            }
            // Each build selects one authoritative reader before diagnostics
            // reach this method. Within that source, retaining the strongest
            // explicit severity prevents a duplicate notice from hiding an
            // error emitted for the same diagnostic identity.
            if diagnostic.severity.rank > existing.severity.rank {
                values[key] = diagnostic
            }
        }
        return values.values.sorted {
            let leftPath = $0.location?.path ?? ""
            let rightPath = $1.location?.path ?? ""
            if leftPath != rightPath {
                return leftPath < rightPath
            }
            if $0.location?.line != $1.location?.line {
                return ($0.location?.line ?? 0) < ($1.location?.line ?? 0)
            }
            return $0.message < $1.message
        }
    }

    private static func unlocatedDiagnostic(from line: String) -> CompilerDiagnostic? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let lowercase = trimmed.lowercased()
        let severity: Severity
        let message: String

        if lowercase.hasPrefix("error:") || lowercase.hasPrefix("fatal error:") {
            severity = .error
            message = String(trimmed.dropFirst(trimmed.firstIndex(of: ":").map {
                trimmed.distance(from: trimmed.startIndex, to: $0) + 1
            } ?? 0)).trimmingCharacters(in: .whitespaces)
        } else if lowercase.hasPrefix("warning:") {
            severity = .warning
            message = String(trimmed.dropFirst("warning:".count))
                .trimmingCharacters(in: .whitespaces)
        } else if lowercase.hasPrefix("note:") || lowercase.hasPrefix("remark:") {
            severity = .notice
            message = String(trimmed.dropFirst(trimmed.firstIndex(of: ":").map {
                trimmed.distance(from: trimmed.startIndex, to: $0) + 1
            } ?? 0)).trimmingCharacters(in: .whitespaces)
        } else if lowercase.hasPrefix("ld:") {
            severity = lowercase.contains("warning") ? .warning : .error
            message = trimmed
        } else if lowercase.contains("phasescriptexecution")
                    && (lowercase.contains("failed") || lowercase.contains("error"))
        {
            severity = .error
            message = trimmed
        } else {
            return nil
        }
        return CompilerDiagnostic(
            message: message,
            severity: severity,
            kind: kind(for: message)
        )
    }

    private static func capture(
        _ match: NSTextCheckingResult,
        group: Int,
        in text: String
    ) -> String? {
        let range = match.range(at: group)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else {
            return nil
        }
        return String(text[swiftRange])
    }

    private static func normalizedPath(_ path: String, projectRoot: URL?) -> String {
        if path.hasPrefix("file://"), let url = URL(string: path) {
            return url.standardizedFileURL.path
        }
        if NSString(string: path).isAbsolutePath {
            return URL(fileURLWithPath: path).standardizedFileURL.path
        }
        if let projectRoot {
            return projectRoot.appendingPathComponent(path).standardizedFileURL.path
        }
        return path
    }

    private static func severity(for value: String) -> Severity {
        switch value.lowercased() {
        case "error": .error
        case "warning": .warning
        default: .notice
        }
    }

    private static func kind(for message: String) -> CompilerDiagnosticKind {
        let value = message.lowercased()
        if value.contains("linker")
            || value.contains("undefined symbol")
            || value.contains("duplicate symbol")
            || value.hasPrefix("ld:")
        {
            return .linker
        }
        if value.contains("no such module")
            || value.contains("could not build module")
            || value.contains("module map")
        {
            return .module
        }
        if value.contains("package")
            || value.contains("dependency")
            || value.contains("binary target")
        {
            return .package
        }
        if value.contains("script")
            || value.contains("command phasescriptexecution failed")
        {
            return .buildPhase
        }
        return .compiler
    }
}
