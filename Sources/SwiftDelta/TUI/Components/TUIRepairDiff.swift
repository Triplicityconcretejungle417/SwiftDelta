//===--- TUIRepairDiff.swift - SwiftDelta ------------------------------------------===//
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
import SwiftDeltaCore

enum TUIRepairDiff {
    static func lines(
        for candidate: RepairCandidatePresentation,
        width: Int,
        ascii: Bool,
        projectRoot: String? = nil
    ) -> [String] {
        let edits = candidate.edits
        guard !edits.isEmpty else {
            return ["No source edit was produced."]
        }
        let canUseSideBySide = width >= 104
        var result: [String] = []
        for (index, edit) in edits.enumerated() {
            if index > 0 { result.append("") }
            let location = edit.sourceRange.map {
                "\($0.start.line):\($0.start.column)"
            } ?? "anchor"
            result.append(
                "\(edit.filePath) · \(location) · \(edit.operation)"
            )
            let context = sourceContext(
                for: edit,
                projectRoot: projectRoot
            )
            if canUseSideBySide {
                result.append(
                    contentsOf: sideBySide(
                        edit,
                        width: width,
                        context: context
                    )
                )
            } else {
                result.append(
                    contentsOf: unified(
                        edit,
                        ascii: ascii,
                        context: context
                    )
                )
            }
        }
        return result
    }

    private static func unified(
        _ edit: RepairCandidateEditPresentation,
        ascii: Bool,
        context: SourceContext
    ) -> [String] {
        let oldLines = sourceLines(edit.originalText)
        let newLines = sourceLines(edit.replacementText)
        let oldStart = edit.sourceRange?.start.line ?? 1
        let newStart = oldStart
        var result = [
            "@@ -\(oldStart),\(oldLines.count) "
                + "+\(newStart),\(newLines.count) @@",
        ]
        result.append(contentsOf: context.before.map {
            "  \(padded($0.line, to: 4)) │ \($0.text)"
        })
        if oldLines.isEmpty {
            result.append(
                ascii ? "- <insertion>" : "− insertion point"
            )
        } else {
            result.append(contentsOf: oldLines.enumerated().map {
                "- \($0.element)  │ \(padded(oldStart + $0.offset, to: 4))"
            })
        }
        if newLines.isEmpty {
            result.append(
                ascii ? "+ <deleted>" : "+ deleted"
            )
        } else {
            result.append(contentsOf: newLines.enumerated().map {
                "+ \($0.element)  │ \(padded(newStart + $0.offset, to: 4))"
            })
        }
        result.append(contentsOf: context.after.map {
            "  \(padded($0.line, to: 4)) │ \($0.text)"
        })
        return result
    }

    private static func sideBySide(
        _ edit: RepairCandidateEditPresentation,
        width: Int,
        context: SourceContext
    ) -> [String] {
        let oldLines = sourceLines(edit.originalText)
        let newLines = sourceLines(edit.replacementText)
        let count = max(1, max(oldLines.count, newLines.count))
        let gutter = " │ "
        let minimumColumnWidth = max(20, (width - gutter.count) / 2)
        let startLine = edit.sourceRange?.start.line ?? 1
        let oldValues = (0..<count).map { index in
            index < oldLines.count
                ? "- \(padded(startLine + index, to: 4)) │ \(oldLines[index])"
                : ""
        }
        let newValues = (0..<count).map { index in
            index < newLines.count
                ? "+ \(padded(startLine + index, to: 4)) │ \(newLines[index])"
                : ""
        }
        let contextValues = (context.before + context.after).map {
            "  \(padded($0.line, to: 4)) │ \($0.text)"
        }
        let columnWidth = max(
            minimumColumnWidth,
            (oldValues + newValues + contextValues)
                .map(TerminalText.displayWidth)
                .max() ?? minimumColumnWidth
        )
        var result = [
            "BASELINE".padding(toLength: columnWidth, withPad: " ", startingAt: 0)
                + gutter + "CANDIDATE",
        ]
        result.append(contentsOf: context.before.map {
            let value = "  \(padded($0.line, to: 4)) │ \($0.text)"
            return paddedToWidth(value, width: columnWidth)
                + gutter + value
        })
        for index in 0..<count {
            result.append(
                paddedToWidth(oldValues[index], width: columnWidth)
                    + gutter
                    + newValues[index]
            )
        }
        result.append(contentsOf: context.after.map {
            let value = "  \(padded($0.line, to: 4)) │ \($0.text)"
            return paddedToWidth(value, width: columnWidth)
                + gutter + value
        })
        return result
    }

    private static func sourceLines(_ source: String) -> [String] {
        guard !source.isEmpty else { return [] }
        return source.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
    }

    private static func padded(_ value: Int, to width: Int) -> String {
        let text = String(value)
        return String(repeating: " ", count: max(0, width - text.count)) + text
    }

    private static func paddedToWidth(
        _ value: String,
        width: Int
    ) -> String {
        value + String(
            repeating: " ",
            count: max(0, width - TerminalText.displayWidth(value))
        )
    }

    private struct SourceContext {
        var before: [(line: Int, text: String)] = []
        var after: [(line: Int, text: String)] = []
    }

    private static func sourceContext(
        for edit: RepairCandidateEditPresentation,
        projectRoot: String?
    ) -> SourceContext {
        guard let projectRoot,
              let range = edit.sourceRange
        else {
            return SourceContext()
        }
        let root = URL(fileURLWithPath: projectRoot, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let source = NSString(string: edit.filePath).isAbsolutePath
            ? URL(fileURLWithPath: edit.filePath)
            : root.appendingPathComponent(edit.filePath)
        let resolved = source.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path == root.path
                || resolved.path.hasPrefix(root.path + "/"),
              let data = try? Data(contentsOf: resolved),
              let text = String(data: data, encoding: .utf8)
        else {
            return SourceContext()
        }
        let lines = text.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        let beforeStart = max(1, range.start.line - 2)
        let beforeEnd = max(0, range.start.line - 1)
        let afterStart = range.end.line + 1
        let afterEnd = min(lines.count, range.end.line + 2)
        let before = beforeStart <= beforeEnd
            ? (beforeStart...beforeEnd).compactMap { line in
                lines.indices.contains(line - 1)
                    ? (line: line, text: lines[line - 1]) : nil
            }
            : []
        let after = afterStart <= afterEnd
            ? (afterStart...afterEnd).compactMap { line in
                lines.indices.contains(line - 1)
                    ? (line: line, text: lines[line - 1]) : nil
            }
            : []
        return SourceContext(before: before, after: after)
    }
}
