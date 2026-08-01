//===--- OperationPixelAnimation.swift - SwiftDelta ------------------------------------------===//
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

enum OperationPixelAnimation {
    enum Tone: Hashable, Sendable {
        case shadow
        case baselineDepth
        case baseline
        case candidateDepth
        case candidate
        case code
        case stream
    }

    struct Cell: Hashable, Sendable {
        let row: Int
        let column: Int
        let character: String
        let tone: Tone
    }

    struct Frame: Hashable, Sendable {
        static let width = 30
        static let height = 6
        static let phaseCount = 24

        let phase: Int
        let caption: String
        let cells: [Cell]
    }

    private static let bird = [
        "   ▄███████████ ",
        "  ▀▀   ▄██████  ",
        "     ▄████▀▀██▄ ",
        "   ▄▀██▀   ██▀  ",
        "          █▀    ",
    ]

    private struct AnimationState {
        let role: Tone
        let codeWave: Int?
        let flowBoundary: Int?
    }

    static func frame(
        for operation: TUIOperationKind,
        tick: Int,
        capabilities: TerminalCapabilities
    ) -> Frame {
        let phase = capabilities.reducedMotion
            ? Frame.phaseCount - 1
            : positiveModulo(tick, divisor: Frame.phaseCount)
        var layers: [[Cell]] = Array(repeating: [], count: 7)

        if capabilities.reducedMotion {
            appendBird(
                at: 7,
                role: .candidate,
                columns: nil,
                codeWave: nil,
                flowBoundary: nil,
                capabilities: capabilities,
                layers: &layers
            )
        } else {
            appendAnimatedMarks(
                phase: phase,
                capabilities: capabilities,
                layers: &layers
            )
        }

        return Frame(
            phase: phase,
            caption: capabilities.reducedMotion
                ? "\(shortLabel(for: operation)) in progress"
                : animatedCaption(for: operation),
            cells: layers.flatMap { $0 }
        )
    }

    static func draw(
        _ frame: Frame,
        on canvas: inout TerminalCanvas,
        row: Int,
        column: Int,
        theme: TerminalTheme,
        capabilities: TerminalCapabilities
    ) {
        for cell in frame.cells {
            canvas.write(
                cell.character,
                row: row + cell.row,
                column: column + cell.column,
                style: style(
                    for: cell.tone,
                    theme: theme,
                    capabilities: capabilities
                ),
                maximumWidth: 1
            )
        }
    }

    private static func appendAnimatedMarks(
        phase: Int,
        capabilities: TerminalCapabilities,
        layers: inout [[Cell]]
    ) {
        let state = animationState(phase: phase)
        appendBird(
            at: 7,
            role: state.role,
            columns: nil,
            codeWave: state.codeWave,
            flowBoundary: state.flowBoundary,
            capabilities: capabilities,
            layers: &layers
        )
    }

    private static func animationState(phase: Int) -> AnimationState {
        let wavePositions = [2, 4, 6, 8, 10, 12, 14, 16]
        switch phase {
        case 0..<8:
            return AnimationState(
                role: .baseline,
                codeWave: wavePositions[phase],
                flowBoundary: nil
            )
        case 8..<12:
            return AnimationState(
                role: .baseline,
                codeWave: nil,
                flowBoundary: [2, 6, 10, 15][phase - 8]
            )
        case 12..<20:
            return AnimationState(
                role: .candidate,
                codeWave: wavePositions[phase - 12],
                flowBoundary: nil
            )
        default:
            return AnimationState(
                role: .candidate,
                codeWave: nil,
                flowBoundary: [15, 10, 6, 2][phase - 20]
            )
        }
    }

    private static func appendBird(
        at column: Int,
        role: Tone,
        columns: ClosedRange<Int>?,
        codeWave: Int?,
        flowBoundary: Int? = nil,
        capabilities: TerminalCapabilities,
        layers: inout [[Cell]]
    ) {
        let cells = bird.enumerated().flatMap { row, line in
            Array(line).enumerated().compactMap {
                cellColumn,
                character -> (Int, Int, String, Tone)? in
                guard character != " ",
                      columns?.contains(cellColumn) ?? true
                else {
                    return nil
                }
                let tone = birdTone(
                    role: role,
                    row: row,
                    column: cellColumn,
                    codeWave: codeWave,
                    flowBoundary: flowBoundary
                )
                let sourceCharacter = tone == .code
                    ? codeCharacter(row: row, column: cellColumn)
                    : String(character)
                return (
                    row,
                    column + cellColumn,
                    rendered(
                        sourceCharacter,
                        tone: tone,
                        capabilities: capabilities
                    ),
                    tone
                )
            }
        }
        layers[0].append(contentsOf: cells.compactMap {
            row,
            column,
            _,
            _ in
            guard row + 1 < Frame.height,
                  column + 1 < Frame.width
            else {
                return nil
            }
            return Cell(
                row: row + 1,
                column: column + 1,
                character: capabilities.symbolMode == .ascii ? "." : "█",
                tone: .shadow
            )
        })
        for cell in cells {
            layers[layerIndex(for: cell.3)].append(
                Cell(
                    row: cell.0,
                    column: cell.1,
                    character: cell.2,
                    tone: cell.3
                )
            )
        }
    }

    private static func birdTone(
        role: Tone,
        row: Int,
        column: Int,
        codeWave: Int?,
        flowBoundary: Int?
    ) -> Tone {
        if let flowBoundary {
            if abs(column - flowBoundary) <= 1 {
                return .stream
            }
            let effectiveRole: Tone = column <= flowBoundary
                ? .candidate : .baseline
            return baseBirdTone(
                role: effectiveRole,
                row: row,
                column: column
            )
        }
        if role == .candidate,
           let codeWave,
           abs((column + row * 2) - codeWave) <= 1
        {
            return .code
        }
        if role == .baseline,
           let codeWave,
           abs((column + row * 2) - codeWave) <= 1
        {
            return .code
        }
        return baseBirdTone(role: role, row: row, column: column)
    }

    private static func baseBirdTone(
        role: Tone,
        row: Int,
        column: Int
    ) -> Tone {
        switch role {
        case .baseline:
            return column >= 10 || row >= 3
                ? .baselineDepth
                : .baseline
        case .candidate:
            return column < 4 || row == bird.count - 1
                ? .candidateDepth
                : .candidate
        default:
            return role
        }
    }

    private static func codeCharacter(row: Int, column: Int) -> String {
        let characters = ["{", "}", "<", ">", "/", "=", "+"]
        return characters[(row * 3 + column) % characters.count]
    }

    private static func layerIndex(for tone: Tone) -> Int {
        switch tone {
        case .shadow: 0
        case .baselineDepth: 1
        case .baseline: 2
        case .candidateDepth: 3
        case .candidate: 4
        case .code: 5
        case .stream: 6
        }
    }

    private static func rendered(
        _ character: String,
        tone: Tone,
        capabilities: TerminalCapabilities
    ) -> String {
        guard capabilities.symbolMode == .ascii else { return character }
        return switch tone {
        case .shadow: "."
        case .baselineDepth: ":"
        case .baseline: "+"
        case .candidateDepth, .candidate: "#"
        case .code: character
        case .stream: "="
        }
    }

    private static func style(
        for tone: Tone,
        theme: TerminalTheme,
        capabilities: TerminalCapabilities
    ) -> TerminalStyle {
        if capabilities.highContrast
            || capabilities.colorMode == .monochrome
        {
            return TerminalStyle(
                foreground: theme.text,
                background: theme.background,
                bold: tone == .candidate
                    || tone == .code
                    || tone == .stream,
                dim: (tone == .shadow
                    || tone == .baselineDepth
                    || tone == .baseline)
                    && !capabilities.highContrast
            )
        }
        let foreground = switch tone {
        case .shadow: DeltaMark.shadowColor
        case .baselineDepth: DeltaMark.baselineDepthColor
        case .baseline: DeltaMark.baselineColor
        case .candidateDepth: DeltaMark.candidateDepthColor
        case .candidate: DeltaMark.brandColor
        case .code: DeltaMark.candidateHighlightColor
        case .stream: DeltaMark.brandColor
        }
        return TerminalStyle(
            foreground: foreground,
            background: theme.background,
            bold: tone == .candidate
                || tone == .code
                || tone == .stream,
            dim: tone == .shadow
        )
    }

    private static func animatedCaption(
        for operation: TUIOperationKind
    ) -> String {
        switch operation {
        case .automaticSetup: "SETUP · resolving context"
        case .discover: "PROJECT · inspecting targets"
        case .scan: "ANALYZE · resolving SDK evidence"
        case .compare: "COMPARE · aligning toolchains"
        case .doctor: "DOCTOR · validating setup"
        case .planRepair: "PLAN · evaluating evidence"
        case .validateRepair: "VERIFY · isolated candidate"
        case .applyRepair: "VERIFY · checking candidate"
        case .exportReport, .exportRepairPlan:
            "EXPORT · writing output"
        case .cacheStatus, .cachePrune, .cacheClear:
            "CACHE · maintaining entries"
        }
    }

    private static func shortLabel(
        for operation: TUIOperationKind
    ) -> String {
        switch operation {
        case .automaticSetup: "SETUP"
        case .discover: "PROJECT"
        case .scan: "ANALYZE"
        case .compare: "COMPARE"
        case .doctor: "DOCTOR"
        case .planRepair: "PLAN"
        case .validateRepair: "VERIFY"
        case .applyRepair: "VERIFY"
        case .exportReport, .exportRepairPlan: "EXPORT"
        case .cacheStatus, .cachePrune, .cacheClear: "CACHE"
        }
    }

    private static func positiveModulo(
        _ value: Int,
        divisor: Int
    ) -> Int {
        let remainder = value % divisor
        return remainder >= 0 ? remainder : remainder + divisor
    }
}
