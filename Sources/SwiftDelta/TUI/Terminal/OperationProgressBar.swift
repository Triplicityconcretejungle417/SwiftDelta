//===--- OperationProgressBar.swift - SwiftDelta ------------------------------------------===//
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

enum OperationProgressBar {
    static func label(
        for measurement: OperationProgressMeasurement?,
        capabilities: TerminalCapabilities
    ) -> String {
        guard let measurement else {
            return capabilities.symbolMode == .ascii
                ? "Progress - working"
                : "Progress · working"
        }
        let percentage = Int(
            (Double(measurement.completed) / Double(measurement.total) * 100)
                .rounded()
        )
        return "\(measurement.label)  \(measurement.completed) of "
            + "\(measurement.total) · \(percentage)%"
    }

    static func draw(
        measurement: OperationProgressMeasurement?,
        tick: Int,
        on canvas: inout TerminalCanvas,
        row: Int,
        column: Int,
        width: Int,
        theme: TerminalTheme,
        capabilities: TerminalCapabilities
    ) {
        guard width > 0 else { return }
        let activeColumns: Set<Int>
        if let measurement {
            let fraction = Double(measurement.completed)
                / Double(measurement.total)
            let rawCount = Int((fraction * Double(width)).rounded(.down))
            let count = measurement.completed > 0
                ? max(1, rawCount)
                : 0
            activeColumns = Set(0..<min(width, count))
        } else if capabilities.reducedMotion {
            let segmentWidth = max(1, min(width, max(3, width / 8)))
            let start = max(0, (width - segmentWidth) / 2)
            activeColumns = Set(start..<min(width, start + segmentWidth))
        } else {
            let segmentWidth = max(2, min(width, max(4, width / 9)))
            let travel = width + segmentWidth
            let leading = positiveModulo(tick, divisor: max(1, travel))
                - segmentWidth
            activeColumns = Set(
                max(0, leading)..<min(width, leading + segmentWidth)
            )
        }

        let filledCharacter = capabilities.symbolMode == .ascii ? "=" : "█"
        let trackCharacter = capabilities.symbolMode == .ascii ? "-" : "█"
        for index in 0..<width {
            let isActive = activeColumns.contains(index)
            canvas.write(
                isActive ? filledCharacter : trackCharacter,
                row: row,
                column: column + index,
                style: isActive
                    ? activeStyle(
                        theme: theme,
                        capabilities: capabilities
                    )
                    : trackStyle(
                        theme: theme,
                        capabilities: capabilities
                    ),
                maximumWidth: 1
            )
        }
    }

    private static func activeStyle(
        theme: TerminalTheme,
        capabilities: TerminalCapabilities
    ) -> TerminalStyle {
        guard !capabilities.highContrast,
              capabilities.colorMode != .monochrome
        else {
            return TerminalStyle(
                foreground: theme.text,
                background: theme.background,
                bold: true
            )
        }
        return TerminalStyle(
            foreground: DeltaMark.brandColor,
            background: theme.background,
            bold: true
        )
    }

    private static func trackStyle(
        theme: TerminalTheme,
        capabilities: TerminalCapabilities
    ) -> TerminalStyle {
        TerminalStyle(
            foreground: theme.text,
            background: theme.background,
            dim: !capabilities.highContrast
        )
    }

    private static func positiveModulo(
        _ value: Int,
        divisor: Int
    ) -> Int {
        let remainder = value % divisor
        return remainder >= 0 ? remainder : remainder + divisor
    }
}
