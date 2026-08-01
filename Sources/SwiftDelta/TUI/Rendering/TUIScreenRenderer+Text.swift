//===--- TUIScreenRenderer+Text.swift - SwiftDelta ------------------------------------------===//
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

extension TUIScreenRenderer {
    func drawWrapped(
        _ lines: [String],
        row: Int,
        column: Int,
        width: Int,
        height: Int,
        scroll: Int,
        on canvas: inout TerminalCanvas,
        diff: Bool = false,
        background: TerminalColor? = nil,
        reverse: Bool = false,
        horizontalScroll: Int = 0,
        headingLines: Set<String> = [],
        semanticRoles: [String: TerminalStyleRole] = [:]
    ) {
        guard width > 0, height > 0 else { return }
        var wrapped: [(String, TerminalStyleRole)] = []
        for line in lines {
            let role: TerminalStyleRole
            if let semanticRole = semanticRoles[line] {
                role = semanticRole
            } else if headingLines.contains(line) {
                role = .header
            } else if diff, line.hasPrefix("+") {
                role = .diffAdded
            } else if diff, line.hasPrefix("-") {
                role = .diffRemoved
            } else if diff {
                role = .diffContext
            } else {
                role = .normal
            }
            let clean = TerminalText.sanitize(line)
            if clean.isEmpty {
                wrapped.append(("", role))
                continue
            }
            if diff {
                wrapped.append(
                    (
                        TerminalText.clipped(
                            TerminalText.droppingColumns(
                                clean,
                                count: horizontalScroll
                            ),
                            width: width
                        ),
                        role
                    )
                )
                continue
            }
            var remainder = clean
            while !remainder.isEmpty {
                let piece = TerminalText.clipped(remainder, width: width)
                guard !piece.isEmpty else { break }
                wrapped.append((piece, role))
                remainder.removeFirst(piece.count)
            }
        }
        let start = min(max(0, scroll), max(0, wrapped.count - height))
        for visible in 0..<height {
            let index = start + visible
            guard index < wrapped.count else { break }
            var style = theme.style(
                wrapped[index].1,
                highContrast: capabilities.highContrast
            )
            if let background {
                style.background = background
            }
            style.reverse = reverse
            let renderedLine = wrapped[index].0
            if diff,
               horizontalScroll == 0,
               let divider = sideBySideDivider(in: renderedLine)
            {
                let left = String(renderedLine[..<divider.lowerBound])
                let right = String(renderedLine[divider.upperBound...])
                let leftWidth = TerminalText.displayWidth(left)
                let dividerWidth = 3
                let leftRole: TerminalStyleRole =
                    left.trimmingCharacters(in: .whitespaces).hasPrefix("-")
                    ? .diffRemoved : .diffContext
                let rightRole: TerminalStyleRole =
                    right.trimmingCharacters(in: .whitespaces).hasPrefix("+")
                    ? .diffAdded : .diffContext
                canvas.write(
                    left,
                    row: row + visible,
                    column: column,
                    style: theme.style(
                        leftRole,
                        highContrast: capabilities.highContrast
                    ),
                    maximumWidth: min(width, leftWidth)
                )
                canvas.write(
                    " │ ",
                    row: row + visible,
                    column: column + leftWidth,
                    style: theme.style(
                        .diffContext,
                        highContrast: capabilities.highContrast
                    ),
                    maximumWidth: max(0, width - leftWidth)
                )
                canvas.write(
                    right,
                    row: row + visible,
                    column: column + leftWidth + dividerWidth,
                    style: theme.style(
                        rightRole,
                        highContrast: capabilities.highContrast
                    ),
                    maximumWidth: max(
                        0,
                        width - leftWidth - dividerWidth
                    )
                )
            } else {
                canvas.write(
                    renderedLine,
                    row: row + visible,
                    column: column,
                    style: style,
                    maximumWidth: width
                )
            }
        }
    }

    private func sideBySideDivider(
        in line: String
    ) -> Range<String.Index>? {
        let separator = " │ "
        var ranges: [Range<String.Index>] = []
        var searchStart = line.startIndex
        while searchStart < line.endIndex,
              let range = line.range(
                of: separator,
                range: searchStart..<line.endIndex
              )
        {
            ranges.append(range)
            searchStart = range.upperBound
        }
        guard !ranges.isEmpty else { return nil }
        if let addedDivider = ranges.first(where: { range in
            line[range.upperBound...]
                .trimmingCharacters(in: .whitespaces)
                .hasPrefix("+")
        }) {
            return addedDivider
        }
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("-") {
            return ranges.last
        }
        return nil
    }

    func severityStyle(_ severity: Severity) -> TerminalStyle {
        theme.style(
            severity == .error
                ? .error
                : (severity == .warning ? .warning : .secondary),
            highContrast: capabilities.highContrast
        )
    }

    func severityLabel(_ severity: Severity) -> String {
        switch severity {
        case .error: return capabilities.symbolMode == .ascii ? "ERR" : "E"
        case .warning: return capabilities.symbolMode == .ascii ? "WRN" : "W"
        case .notice: return capabilities.symbolMode == .ascii ? "NTE" : "N"
        }
    }

    func statusText(_ status: TUIOperationStatus) -> String {
        switch status {
        case .idle:
            return ""
        case let .running(kind, _):
            return "RUNNING · \(kind.title)"
        case let .succeeded(_, message):
            return message
        case let .cancelled(kind):
            return "CANCELLED · \(kind.title)"
        case let .failed(kind, _, _):
            return "FAILED · \(kind.title)"
        }
    }

    func statusColor(_ status: TUIOperationStatus) -> TerminalColor {
        switch status {
        case .idle, .running:
            return theme.accent
        case .succeeded:
            return theme.mint
        case .cancelled:
            return theme.warning
        case .failed:
            return theme.error
        }
    }}
