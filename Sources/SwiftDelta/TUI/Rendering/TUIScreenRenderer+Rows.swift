//===--- TUIScreenRenderer+Rows.swift - SwiftDelta ------------------------------------------===//
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
    func renderBrandedRows(
        _ state: TUIState,
        row: Int,
        column: Int,
        width: Int,
        height: Int,
        on canvas: inout TerminalCanvas
    ) {
        let layout = TUILayoutMode(columns: width)
        if layout == .wide, height >= 18 {
            let brandWidth = min(48, max(44, width / 3))
            DeltaMark.drawLarge(
                on: &canvas,
                row: row,
                column: column + max(
                    0,
                    (brandWidth - DeltaMark.largeTerminalSize.columns) / 2
                ),
                theme: theme,
                capabilities: capabilities
            )
            renderRows(
                TUIContentRows.rows(for: state),
                selectedIndex: state.contentIndex,
                row: row,
                column: column + brandWidth,
                width: width - brandWidth,
                height: height,
                on: &canvas
            )
        } else if layout == .medium, height >= 14 {
            DeltaMark.drawMediumBrand(
                on: &canvas,
                row: row + 1,
                column: column,
                theme: theme,
                capabilities: capabilities
            )
            renderRows(
                TUIContentRows.rows(for: state),
                selectedIndex: state.contentIndex,
                row: row,
                column: column + 26,
                width: width - 26,
                height: height,
                on: &canvas
            )
        } else {
            if height >= 16 {
                DeltaMark.drawCompactBrand(
                    on: &canvas,
                    row: row,
                    column: column + 1,
                    theme: theme,
                    capabilities: capabilities
                )
            }
            let offset = height >= 16
                ? DeltaMark.compactTerminalSize.rows + 1
                : 0
            renderRows(
                TUIContentRows.rows(for: state),
                selectedIndex: state.contentIndex,
                row: row + offset,
                column: column,
                width: width,
                height: max(1, height - offset),
                on: &canvas
            )
        }
    }

    func renderRows(
        _ rows: [TUIRow],
        selectedIndex: Int,
        row: Int,
        column: Int,
        width: Int,
        height: Int,
        on canvas: inout TerminalCanvas
    ) {
        guard !rows.isEmpty else {
            canvas.write(
                "Nothing to show.",
                row: row + 1,
                column: column + 1,
                style: theme.style(
                    .secondary,
                    highContrast: capabilities.highContrast
                )
            )
            return
        }
        let displayIndices = TUIContentRows.displayedRowIndices(for: rows)
        let detailHeight = height >= 8 ? 3 : 0
        let visibleCount = max(1, height - detailHeight)
        let selected = min(max(0, selectedIndex), rows.count - 1)
        let selectedDisplay = displayIndices.firstIndex { $0 == selected } ?? 0
        let start = min(
            max(0, selectedDisplay - visibleCount / 2),
            max(0, displayIndices.count - visibleCount)
        )
        for visibleIndex in 0..<visibleCount {
            let displayIndex = start + visibleIndex
            guard displayIndices.indices.contains(displayIndex) else { break }
            guard let index = displayIndices[displayIndex] else {
                let nextIndex = displayIndices.dropFirst(displayIndex + 1)
                    .compactMap { $0 }
                    .first
                if let section = nextIndex.flatMap({ rows[$0].section }) {
                    canvas.write(
                        section.rawValue,
                        row: row + visibleIndex,
                        column: column + 1,
                        style: theme.style(
                            section == .actions ? .header : .secondary,
                            highContrast: capabilities.highContrast
                        ),
                        maximumWidth: max(0, width - 2)
                    )
                }
                continue
            }
            let item = rows[index]
            let y = row + visibleIndex
            renderControlRow(
                item,
                selected: index == selected,
                row: y,
                column: column,
                width: width,
                on: &canvas
            )
        }
        if detailHeight > 0 {
            canvas.write(
                rows[selected].detail,
                row: row + height - 2,
                column: column + 2,
                style: theme.style(
                    .secondary,
                    highContrast: capabilities.highContrast
                ),
                maximumWidth: max(0, width - 4)
            )
        }
    }

    func renderControlRow(
        _ item: TUIRow,
        selected: Bool,
        row: Int,
        column: Int,
        width: Int,
        on canvas: inout TerminalCanvas
    ) {
        let style = controlStyle(for: item, selected: selected)
        if selected {
            canvas.fill(
                row: row,
                from: column,
                width: width,
                style: style
            )
        }
        let label = controlLabel(item)
        let desiredLabelWidth = TerminalText.displayWidth(label) + 1
        let labelWidth = min(
            max(16, width - 8),
            max(min(30, max(16, width / 3)), desiredLabelWidth)
        )
        canvas.write(
            label,
            row: row,
            column: column + 1,
            style: style,
            maximumWidth: labelWidth
        )
        canvas.write(
            TerminalText.truncated(
                item.value,
                width: max(4, width - labelWidth - 4)
            ),
            row: row,
            column: column + labelWidth + 2,
            style: item.enabled ? style : controlStyle(
                for: item,
                selected: selected
            ),
            maximumWidth: max(0, width - labelWidth - 3)
        )
    }

    private func controlLabel(_ item: TUIRow) -> String {
        let label = switch item.prominence {
        case .primary:
            item.enabled
                ? "[ \(item.label) ]" : "[- \(item.label) -]"
        case .destructive:
            item.enabled
                ? "[! \(item.label) ]" : "[- \(item.label) -]"
        case .destination:
            item.enabled
                ? "[ \(item.label) ]" : "[- \(item.label) -]"
        case .standard, .secondary:
            item.label
        }
        return "  " + label
    }

    private func controlStyle(
        for item: TUIRow,
        selected: Bool
    ) -> TerminalStyle {
        if selected {
            let selectionRole: TerminalSelectionRole
            if !item.enabled {
                selectionRole = .disabled
            } else {
                selectionRole = switch item.prominence {
                case .primary: .primary
                case .destructive: .destructive
                case .destination, .secondary, .standard: .normal
                }
            }
            return theme.selectionStyle(
                selectionRole,
                capabilities: capabilities
            )
        }
        let role: TerminalStyleRole
        if !item.enabled {
            role = .disabled
        } else {
            role = switch item.prominence {
            case .primary: .primaryAction
            case .destructive: .destructive
            case .destination: .header
            case .secondary: .secondary
            case .standard: .normal
            }
        }
        return theme.style(
            role,
            highContrast: capabilities.highContrast
        )
    }

}
