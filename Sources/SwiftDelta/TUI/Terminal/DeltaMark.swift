//===--- DeltaMark.swift - SwiftDelta ------------------------------------------===//
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

/// Responsive Home branding built from two layered Swift-bird silhouettes.
///
/// The baseline bird sits lower and behind the candidate bird. Both shapes
/// retain independent tails and beaks so the overlap reads as a transition,
/// while a fixed one-cell shadow gives the mark and wordmark consistent depth.
struct DeltaMark {
    static let brandColor = TerminalColor.rgb(240, 81, 56)
    static let candidateDepthColor = TerminalColor.rgb(216, 65, 44)
    static let candidateHighlightColor = TerminalColor.rgb(255, 154, 132)
    static let baselineColor = TerminalColor.rgb(194, 70, 50)
    static let baselineDepthColor = TerminalColor.rgb(145, 58, 43)
    static let shadowColor = TerminalColor.rgb(104, 96, 93)

    private static let fullBird = raster(
        width: 24,
        segments: [
            [11...15],
            [8...18, 22...23],
            [6...23],
            [4...22],
            [3...7, 11...22],
            [2...3, 13...21],
            [12...21],
            [11...21],
            [10...21],
            [8...14, 17...21],
            [7...13, 17...21],
            [6...8, 10...11, 17...20],
            [6...7, 9...10, 17...20],
            [5...5, 8...9, 17...19],
            [7...7, 17...18],
            [16...17],
            [16...16],
        ]
    )

    private static let mediumBird = raster(
        width: 16,
        segments: [
            [4...14],
            [3...14],
            [2...3, 8...13],
            [7...13],
            [6...13],
            [5...9, 12...14],
            [4...7, 11...13],
            [3...3, 5...6, 11...12],
            [10...11],
            [10...10],
        ]
    )

    private static let compactBird = raster(
        width: 10,
        segments: [
            [4...5],
            [2...9],
            [1...1, 5...8],
            [4...8],
            [3...5, 7...8],
            [2...3, 7...7],
            [6...7],
        ]
    )

    private static let fullWordmarkGlyphs: [Character: [String]] = [
        "S": [
            "01110", "10000", "10000", "01110",
            "00001", "00001", "11110",
        ],
        "W": [
            "10001", "10001", "10001", "10101",
            "10101", "11011", "10001",
        ],
        "I": [
            "111", "010", "010", "010",
            "010", "010", "111",
        ],
        "F": [
            "11111", "10000", "10000", "11110",
            "10000", "10000", "10000",
        ],
        "T": [
            "11111", "00100", "00100", "00100",
            "00100", "00100", "00100",
        ],
        "D": [
            "11110", "10001", "10001", "10001",
            "10001", "10001", "11110",
        ],
        "E": [
            "11111", "10000", "10000", "11110",
            "10000", "10000", "11111",
        ],
        "L": [
            "10000", "10000", "10000", "10000",
            "10000", "10000", "11111",
        ],
        "A": [
            "01110", "10001", "10001", "11111",
            "10001", "10001", "10001",
        ],
    ]

    private static let compactWordmarkGlyphs: [Character: [String]] = [
        "S": ["1111", "1000", "1110", "0001", "1110"],
        "W": ["10001", "10001", "10101", "11011", "10001"],
        "I": ["1", "1", "1", "1", "1"],
        "F": ["1111", "1000", "1110", "1000", "1000"],
        "T": ["11111", "00100", "00100", "00100", "00100"],
        "D": ["1110", "1001", "1001", "1001", "1110"],
        "E": ["1111", "1000", "1110", "1000", "1111"],
        "L": ["1000", "1000", "1000", "1000", "1111"],
        "A": ["0110", "1001", "1111", "1001", "1001"],
    ]

    private struct BirdComposition {
        let bird: [String]
        let baselineRow: Int
        let baselineColumn: Int
        let candidateRow: Int
        let candidateColumn: Int
    }

    private static let fullComposition = BirdComposition(
        bird: fullBird,
        baselineRow: 1,
        baselineColumn: 0,
        candidateRow: 0,
        candidateColumn: 13
    )

    private static let mediumComposition = BirdComposition(
        bird: mediumBird,
        baselineRow: 1,
        baselineColumn: 0,
        candidateRow: 0,
        candidateColumn: 6
    )

    private static let compactComposition = BirdComposition(
        bird: compactBird,
        baselineRow: 0,
        baselineColumn: 0,
        candidateRow: 0,
        candidateColumn: 4
    )

    static func drawWelcome(
        on canvas: inout TerminalCanvas,
        row: Int,
        column: Int,
        theme: TerminalTheme,
        capabilities: TerminalCapabilities
    ) {
        drawLarge(
            on: &canvas,
            row: row,
            column: column,
            theme: theme,
            capabilities: capabilities
        )
    }

    static func drawLarge(
        on canvas: inout TerminalCanvas,
        row: Int,
        column: Int,
        theme: TerminalTheme,
        capabilities: TerminalCapabilities
    ) {
        drawBirds(
            fullComposition,
            row: row,
            column: column,
            theme: theme,
            capabilities: capabilities,
            on: &canvas
        )
        let wordmark = stackedWordmark(
            words: ["SWIFT", "DELTA"],
            glyphs: fullWordmarkGlyphs
        )
        drawShadowedRaster(
            wordmark,
            row: row + birdTerminalSize(fullComposition).rows + 1,
            column: column + centeredOffset(
                outerWidth: birdTerminalSize(fullComposition).columns,
                innerWidth: shadowedWidth(of: wordmark)
            ),
            theme: theme,
            capabilities: capabilities,
            on: &canvas
        )
    }

    static func drawMediumBrand(
        on canvas: inout TerminalCanvas,
        row: Int,
        column: Int,
        theme: TerminalTheme,
        capabilities: TerminalCapabilities
    ) {
        drawBirds(
            mediumComposition,
            row: row,
            column: column,
            theme: theme,
            capabilities: capabilities,
            on: &canvas
        )
        let wordmark = stackedWordmark(
            words: ["SWIFT", "DELTA"],
            glyphs: compactWordmarkGlyphs
        )
        drawShadowedRaster(
            wordmark,
            row: row + birdTerminalSize(mediumComposition).rows + 1,
            column: column + centeredOffset(
                outerWidth: birdTerminalSize(mediumComposition).columns,
                innerWidth: shadowedWidth(of: wordmark)
            ),
            theme: theme,
            capabilities: capabilities,
            on: &canvas
        )
    }

    static func drawCompactBrand(
        on canvas: inout TerminalCanvas,
        row: Int,
        column: Int,
        theme: TerminalTheme,
        capabilities: TerminalCapabilities
    ) {
        drawBirds(
            compactComposition,
            row: row,
            column: column,
            theme: theme,
            capabilities: capabilities,
            on: &canvas
        )
        let wordmark = wordmark(
            "SWIFTDELTA",
            glyphs: compactWordmarkGlyphs
        )
        drawShadowedRaster(
            wordmark,
            row: row,
            column: column
                + birdTerminalSize(compactComposition).columns
                + 3,
            theme: theme,
            capabilities: capabilities,
            on: &canvas
        )
    }

    static var largeTerminalSize: TerminalSize {
        let birds = birdTerminalSize(fullComposition)
        let wordmark = stackedWordmark(
            words: ["SWIFT", "DELTA"],
            glyphs: fullWordmarkGlyphs
        )
        return TerminalSize(
            columns: max(birds.columns, shadowedWidth(of: wordmark)),
            rows: birds.rows + 1 + shadowedHeight(of: wordmark)
        )
    }

    static var mediumTerminalSize: TerminalSize {
        let birds = birdTerminalSize(mediumComposition)
        let wordmark = stackedWordmark(
            words: ["SWIFT", "DELTA"],
            glyphs: compactWordmarkGlyphs
        )
        return TerminalSize(
            columns: max(birds.columns, shadowedWidth(of: wordmark)),
            rows: birds.rows + 1 + shadowedHeight(of: wordmark)
        )
    }

    static var compactTerminalSize: TerminalSize {
        let birds = birdTerminalSize(compactComposition)
        let wordmark = wordmark(
            "SWIFTDELTA",
            glyphs: compactWordmarkGlyphs
        )
        return TerminalSize(
            columns: birds.columns + 3 + shadowedWidth(of: wordmark),
            rows: max(birds.rows, shadowedHeight(of: wordmark))
        )
    }

    private static func drawBirds(
        _ composition: BirdComposition,
        row: Int,
        column: Int,
        theme: TerminalTheme,
        capabilities: TerminalCapabilities,
        on canvas: inout TerminalCanvas
    ) {
        drawRaster(
            composition.bird,
            row: row + composition.baselineRow + 1,
            column: column + composition.baselineColumn + 1,
            style: pixelStyle(
                .shadow,
                theme: theme,
                capabilities: capabilities
            ),
            asciiCharacter: ".",
            capabilities: capabilities,
            on: &canvas
        )
        drawRaster(
            composition.bird,
            row: row + composition.candidateRow + 1,
            column: column + composition.candidateColumn + 1,
            style: pixelStyle(
                .shadow,
                theme: theme,
                capabilities: capabilities
            ),
            asciiCharacter: ".",
            capabilities: capabilities,
            on: &canvas
        )
        drawShadedRaster(
            composition.bird,
            row: row + composition.baselineRow,
            column: column + composition.baselineColumn,
            layer: .baseline,
            theme: theme,
            capabilities: capabilities,
            on: &canvas
        )
        drawShadedRaster(
            composition.bird,
            row: row + composition.candidateRow,
            column: column + composition.candidateColumn,
            layer: .candidate,
            theme: theme,
            capabilities: capabilities,
            on: &canvas
        )
    }

    private static func drawShadowedRaster(
        _ raster: [String],
        row: Int,
        column: Int,
        theme: TerminalTheme,
        capabilities: TerminalCapabilities,
        on canvas: inout TerminalCanvas
    ) {
        drawRaster(
            raster,
            row: row + 1,
            column: column + 1,
            style: pixelStyle(
                .shadow,
                theme: theme,
                capabilities: capabilities
            ),
            asciiCharacter: ".",
            capabilities: capabilities,
            on: &canvas
        )
        drawShadedRaster(
            raster,
            row: row,
            column: column,
            layer: .wordmark,
            theme: theme,
            capabilities: capabilities,
            on: &canvas
        )
    }

    private enum PixelLayer {
        case shadow
        case baselineDepth
        case baseline
        case candidateDepth
        case candidate
        case candidateHighlight
        case wordmark
    }

    private static func pixelStyle(
        _ layer: PixelLayer,
        theme: TerminalTheme,
        capabilities: TerminalCapabilities
    ) -> TerminalStyle {
        if capabilities.highContrast
            || capabilities.colorMode == .monochrome
        {
            return TerminalStyle(
                foreground: theme.text,
                background: theme.background,
                bold: layer == .candidate || layer == .candidateHighlight,
                dim: layer != .candidate
                    && layer != .candidateHighlight
                    && !capabilities.highContrast
            )
        }
        let color = switch layer {
        case .shadow: shadowColor
        case .baselineDepth: baselineDepthColor
        case .baseline: baselineColor
        case .candidateDepth: candidateDepthColor
        case .candidate: brandColor
        case .candidateHighlight: candidateHighlightColor
        case .wordmark: brandColor
        }
        return TerminalStyle(
            foreground: color,
            background: theme.background,
            bold: layer == .candidate || layer == .candidateHighlight,
            dim: layer == .shadow
        )
    }

    private static func drawShadedRaster(
        _ raster: [String],
        row: Int,
        column: Int,
        layer: PixelLayer,
        theme: TerminalTheme,
        capabilities: TerminalCapabilities,
        on canvas: inout TerminalCanvas
    ) {
        let width = rasterWidth(raster)
        guard width > 0, !raster.isEmpty else { return }
        let pixels = raster.map {
            Array($0.padding(
                toLength: width,
                withPad: " ",
                startingAt: 0
            ))
        }
        for pixelRow in stride(from: 0, to: pixels.count, by: 2) {
            let bottomRow = pixelRow + 1
            for pixelColumn in 0..<width {
                let top = pixels[pixelRow][pixelColumn] == "1"
                let bottom = bottomRow < pixels.count
                    && pixels[bottomRow][pixelColumn] == "1"
                guard top || bottom else { continue }
                let resolvedLayer = shadedLayer(
                    for: layer,
                    pixelRow: pixelRow,
                    pixelColumn: pixelColumn,
                    pixels: pixels
                )
                let character: String
                if capabilities.symbolMode == .ascii {
                    character = asciiCharacter(for: resolvedLayer)
                } else {
                    character = switch (top, bottom) {
                    case (true, true): "█"
                    case (true, false): "▀"
                    case (false, true): "▄"
                    case (false, false): " "
                    }
                }
                canvas.write(
                    character,
                    row: row + pixelRow / 2,
                    column: column + pixelColumn,
                    style: pixelStyle(
                        resolvedLayer,
                        theme: theme,
                        capabilities: capabilities
                    ),
                    maximumWidth: 1
                )
            }
        }
    }

    private static func shadedLayer(
        for layer: PixelLayer,
        pixelRow: Int,
        pixelColumn: Int,
        pixels: [[Character]]
    ) -> PixelLayer {
        let width = pixels.first?.count ?? 0
        switch layer {
        case .baseline:
            let lowerBody = pixelRow >= pixels.count * 2 / 3
            let rearInterior = pixelColumn >= width * 2 / 3
            return lowerBody || rearInterior ? .baselineDepth : .baseline
        case .candidate:
            if isUpperOrLeadingEdge(
                pixelRow: pixelRow,
                pixelColumn: pixelColumn,
                pixels: pixels
            ), pixelColumn >= width / 3 {
                return .candidateHighlight
            }
            let overlapEdge = pixelColumn < width / 3
            let lowerBody = pixelRow >= pixels.count * 4 / 5
            return overlapEdge || lowerBody ? .candidateDepth : .candidate
        case .wordmark:
            if isUpperOrLeadingEdge(
                pixelRow: pixelRow,
                pixelColumn: pixelColumn,
                pixels: pixels
            ) {
                return .candidateHighlight
            }
            if isLowerOrTrailingEdge(
                pixelRow: pixelRow,
                pixelColumn: pixelColumn,
                pixels: pixels
            ) {
                return .candidateDepth
            }
            return .candidate
        default:
            return layer
        }
    }

    private static func isUpperOrLeadingEdge(
        pixelRow: Int,
        pixelColumn: Int,
        pixels: [[Character]]
    ) -> Bool {
        let rows = [pixelRow, pixelRow + 1].filter {
            pixels.indices.contains($0)
                && pixels[$0][pixelColumn] == "1"
        }
        return rows.contains { row in
            row == 0
                || pixels[row - 1][pixelColumn] != "1"
                || pixelColumn == 0
                || pixels[row][pixelColumn - 1] != "1"
        }
    }

    private static func isLowerOrTrailingEdge(
        pixelRow: Int,
        pixelColumn: Int,
        pixels: [[Character]]
    ) -> Bool {
        let rows = [pixelRow, pixelRow + 1].filter {
            pixels.indices.contains($0)
                && pixels[$0][pixelColumn] == "1"
        }
        return rows.contains { row in
            row == pixels.index(before: pixels.endIndex)
                || pixels[row + 1][pixelColumn] != "1"
                || pixelColumn == pixels[row].index(before: pixels[row].endIndex)
                || pixels[row][pixelColumn + 1] != "1"
        }
    }

    private static func asciiCharacter(for layer: PixelLayer) -> String {
        switch layer {
        case .shadow: "."
        case .baselineDepth: ":"
        case .baseline: "+"
        case .candidateDepth, .candidate: "#"
        case .candidateHighlight: "@"
        case .wordmark: "#"
        }
    }

    private static func drawRaster(
        _ raster: [String],
        row: Int,
        column: Int,
        style: TerminalStyle,
        asciiCharacter: String,
        capabilities: TerminalCapabilities,
        on canvas: inout TerminalCanvas
    ) {
        let width = rasterWidth(raster)
        guard width > 0, !raster.isEmpty else { return }
        let pixels = raster.map {
            Array($0.padding(
                toLength: width,
                withPad: " ",
                startingAt: 0
            ))
        }
        for pixelRow in stride(from: 0, to: pixels.count, by: 2) {
            let bottomRow = pixelRow + 1
            for pixelColumn in 0..<width {
                let top = pixels[pixelRow][pixelColumn] == "1"
                let bottom = bottomRow < pixels.count
                    && pixels[bottomRow][pixelColumn] == "1"
                guard top || bottom else { continue }
                let character: String
                if capabilities.symbolMode == .ascii {
                    character = asciiCharacter
                } else {
                    character = switch (top, bottom) {
                    case (true, true): "█"
                    case (true, false): "▀"
                    case (false, true): "▄"
                    case (false, false): " "
                    }
                }
                canvas.write(
                    character,
                    row: row + pixelRow / 2,
                    column: column + pixelColumn,
                    style: style,
                    maximumWidth: 1
                )
            }
        }
    }

    private static func birdTerminalSize(
        _ composition: BirdComposition
    ) -> TerminalSize {
        let birdWidth = rasterWidth(composition.bird)
        let birdHeight = terminalHeight(of: composition.bird)
        let columns = max(
            composition.baselineColumn + birdWidth,
            composition.candidateColumn + birdWidth
        ) + 1
        let rows = max(
            composition.baselineRow + birdHeight,
            composition.candidateRow + birdHeight
        ) + 1
        return TerminalSize(columns: columns, rows: rows)
    }

    private static func shadowedWidth(of raster: [String]) -> Int {
        rasterWidth(raster) + 1
    }

    private static func shadowedHeight(of raster: [String]) -> Int {
        terminalHeight(of: raster) + 1
    }

    private static func stackedWordmark(
        words: [String],
        glyphs: [Character: [String]]
    ) -> [String] {
        let rendered = words.map { wordmark($0, glyphs: glyphs) }
        let width = rendered.map(rasterWidth).max() ?? 0
        var result: [String] = []
        for (index, word) in rendered.enumerated() {
            if index > 0 {
                result.append(String(repeating: " ", count: width))
            }
            let wordWidth = rasterWidth(word)
            let leading = max(0, (width - wordWidth) / 2)
            let trailing = max(0, width - wordWidth - leading)
            result.append(contentsOf: word.map {
                String(repeating: " ", count: leading)
                    + $0
                    + String(repeating: " ", count: trailing)
            })
        }
        return result
    }

    private static func wordmark(
        _ word: String,
        glyphs: [Character: [String]]
    ) -> [String] {
        let letters = Array(word)
        let height = letters.compactMap { glyphs[$0]?.count }.max() ?? 0
        return (0..<height).map { row in
            letters.compactMap { glyphs[$0]?[row] }
                .map(emboldenedGlyphRow)
                .joined(separator: " ")
        }
    }

    /// Expands single-pixel strokes inward without changing a glyph's grid.
    ///
    /// Keeping each row's width stable preserves the Home layout and responsive
    /// breakpoints while giving the wordmark the same visual weight as the birds.
    private static func emboldenedGlyphRow(_ row: String) -> String {
        let source = Array(row)
        guard !source.isEmpty else { return row }
        var result = source
        for index in source.indices where source[index] == "1" {
            if index == source.index(before: source.endIndex) {
                guard index > source.startIndex else { continue }
                result[source.index(before: index)] = "1"
            } else {
                result[source.index(after: index)] = "1"
            }
        }
        return String(result)
    }

    private static func raster(
        width: Int,
        segments: [[ClosedRange<Int>]]
    ) -> [String] {
        segments.map { ranges in
            (0..<width).map { column in
                ranges.contains { $0.contains(column) } ? "1" : " "
            }.joined()
        }
    }

    private static func rasterWidth(_ raster: [String]) -> Int {
        raster.map(\.count).max() ?? 0
    }

    private static func terminalHeight(of raster: [String]) -> Int {
        (raster.count + 1) / 2
    }

    private static func centeredOffset(
        outerWidth: Int,
        innerWidth: Int
    ) -> Int {
        max(0, (outerWidth - innerWidth) / 2)
    }
}
