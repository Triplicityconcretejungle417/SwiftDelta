//===--- TerminalCanvas.swift - SwiftDelta ------------------------------------------===//
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

struct TerminalCell: Equatable, Sendable {
    var text = " "
    var style = TerminalStyle.plain
    var continuation = false
}

struct TerminalCanvas: Sendable {
    let size: TerminalSize
    private(set) var rows: [[TerminalCell]]

    init(size: TerminalSize, fill style: TerminalStyle = .plain) {
        self.size = size
        rows = Array(
            repeating: Array(
                repeating: TerminalCell(text: " ", style: style),
                count: max(0, size.columns)
            ),
            count: max(0, size.rows)
        )
    }

    mutating func fill(
        row: Int,
        from startColumn: Int,
        width: Int,
        style: TerminalStyle
    ) {
        guard rows.indices.contains(row), width > 0 else { return }
        let lower = max(0, startColumn)
        let upper = min(size.columns, startColumn + width)
        guard lower < upper else { return }
        for column in lower..<upper {
            rows[row][column] = TerminalCell(text: " ", style: style)
        }
    }

    mutating func write(
        _ text: String,
        row: Int,
        column: Int,
        style: TerminalStyle,
        maximumWidth: Int? = nil
    ) {
        guard rows.indices.contains(row), column < size.columns else { return }
        let clean = TerminalText.sanitize(text)
        let limit = min(
            size.columns,
            column + (maximumWidth ?? max(0, size.columns - column))
        )
        var cursor = max(0, column)
        for character in clean {
            let string = String(character)
            let width = TerminalText.displayWidth(string)
            guard width > 0 else { continue }
            guard cursor + width <= limit else { break }
            rows[row][cursor] = TerminalCell(
                text: string,
                style: style,
                continuation: false
            )
            if width == 2, cursor + 1 < size.columns {
                rows[row][cursor + 1] = TerminalCell(
                    text: "",
                    style: style,
                    continuation: true
                )
            }
            cursor += width
        }
    }

    mutating func set(
        _ text: String,
        row: Int,
        column: Int,
        style: TerminalStyle
    ) {
        guard rows.indices.contains(row),
              rows[row].indices.contains(column)
        else {
            return
        }
        rows[row][column] = TerminalCell(text: text, style: style)
    }

    func encodedLines(
        theme: TerminalTheme,
        capabilities: TerminalCapabilities
    ) -> [String] {
        rows.map { row in
            var encoded = ""
            var activeStyle: TerminalStyle?
            for cell in row where !cell.continuation {
                if activeStyle != cell.style {
                    encoded += theme.sequence(
                        for: cell.style,
                        capabilities: capabilities
                    )
                    activeStyle = cell.style
                }
                encoded += cell.text
            }
            return encoded + TerminalControl.reset
        }
    }
}

final class DifferentialTerminalRenderer {
    private let output: FileHandle
    private var previous: [String] = []

    init(output: FileHandle = .standardOutput) {
        self.output = output
    }

    func render(
        _ canvas: TerminalCanvas,
        theme: TerminalTheme,
        capabilities: TerminalCapabilities,
        force: Bool = false
    ) {
        let lines = canvas.encodedLines(
            theme: theme,
            capabilities: capabilities
        )
        var data = ""
        for index in lines.indices {
            if force || index >= previous.count || previous[index] != lines[index] {
                data += TerminalControl.move(row: index + 1, column: 1)
                data += lines[index]
            }
        }
        if previous.count > lines.count {
            for index in lines.count..<previous.count {
                data += TerminalControl.move(row: index + 1, column: 1)
                data += TerminalControl.clearLine
            }
        }
        if !data.isEmpty {
            output.write(Data(data.utf8))
        }
        previous = lines
    }

    func invalidate() {
        previous.removeAll()
    }
}
