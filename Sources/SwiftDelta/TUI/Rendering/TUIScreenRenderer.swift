//===--- TUIScreenRenderer.swift - SwiftDelta ------------------------------------------===//
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

struct TUIScreenRenderer {
    let theme: TerminalTheme
    let capabilities: TerminalCapabilities
    let now: @Sendable () -> Date

    init(
        theme: TerminalTheme,
        capabilities: TerminalCapabilities,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.theme = theme
        self.capabilities = capabilities
        self.now = now
    }

    func render(_ state: TUIState, size: TerminalSize) -> TerminalCanvas {
        let normal = theme.style(
            .normal,
            highContrast: capabilities.highContrast
        )
        var canvas = TerminalCanvas(size: size, fill: normal)
        guard size.isUsable else {
            renderMinimumSize(state, on: &canvas)
            return canvas
        }
        renderHeader(state, on: &canvas)
        renderLocation(state, on: &canvas)
        let contentColumn = 2
        let contentWidth = max(1, size.columns - 4)
        let contentRow = 3
        let contentHeight = max(1, size.rows - contentRow - 2)
        renderContent(
            state,
            row: contentRow,
            column: contentColumn,
            width: contentWidth,
            height: contentHeight,
            on: &canvas
        )
        renderFooter(state, on: &canvas)
        renderOperation(state, on: &canvas)
        renderOverlay(state, on: &canvas)
        return canvas
    }

    func renderLocation(
        _ state: TUIState,
        on canvas: inout TerminalCanvas
    ) {
        let home = "Home"
        let title = state.screen == .project
            ? home
            : "\(home)  \(TerminalSymbols(capabilities: capabilities).disclosure)  \(state.screen.title)"
        let selected = state.focus == .navigation
        let style = selected
            ? theme.selectionStyle(
                .normal,
                capabilities: capabilities
            )
            : theme.style(
                .secondary,
                highContrast: capabilities.highContrast
            )
        if selected {
            canvas.fill(
                row: 1,
                from: 1,
                width: max(0, canvas.size.columns - 2),
                style: style
            )
        }
        canvas.write(
            title,
            row: 1,
            column: 2,
            style: style,
            maximumWidth: max(0, canvas.size.columns - 4)
        )
        let divider = capabilities.symbolMode == .unicode ? "─" : "-"
        for column in 1..<(canvas.size.columns - 1) {
            canvas.write(
                divider,
                row: 2,
                column: column,
                style: TerminalStyle(
                    foreground: theme.elevated,
                    background: theme.background
                )
            )
        }
    }

    func renderHeader(_ state: TUIState, on canvas: inout TerminalCanvas) {
        let style = theme.style(
            .header,
            highContrast: capabilities.highContrast
        )
        canvas.fill(
            row: 0,
            from: 0,
            width: canvas.size.columns,
            style: style
        )
        let status = statusText(state.operationStatus)
        let trailingWidth: Int
        if state.safeMode {
            trailingWidth = 11
        } else if !status.isEmpty {
            trailingWidth = TerminalText.displayWidth(status) + 2
        } else {
            trailingWidth = 0
        }
        let titleWidth = max(
            1,
            canvas.size.columns - 4 - trailingWidth
        )
        canvas.write(
            TerminalText.truncated(
                state.projectDisplayName,
                width: titleWidth
            ),
            row: 0,
            column: 2,
            style: style,
            maximumWidth: titleWidth
        )
        if !status.isEmpty, !state.safeMode {
            canvas.write(
                status,
                row: 0,
                column: max(2, canvas.size.columns - status.count - 3),
                style: TerminalStyle(
                    foreground: statusColor(state.operationStatus),
                    background: theme.background,
                    bold: true
                ),
                maximumWidth: min(status.count, canvas.size.columns - 4)
            )
        }
        if state.safeMode {
            canvas.write(
                "SAFE MODE",
                row: 0,
                column: max(2, canvas.size.columns - 11),
                style: TerminalStyle(
                    foreground: theme.warning,
                    background: theme.background,
                    bold: true
                )
            )
        }
    }

    func renderContent(
        _ state: TUIState,
        row: Int,
        column: Int,
        width: Int,
        height: Int,
        on canvas: inout TerminalCanvas
    ) {
        if state.detailPresentation == .finding,
           let finding = state.selectedFinding
        {
            renderDetailHeader(
                "Finding · Esc returns to Analysis",
                row: row,
                column: column,
                width: width,
                on: &canvas
            )
            renderFindingDetail(
                finding,
                row: row + 2,
                column: column,
                width: width,
                height: max(1, height - 2),
                scroll: state.detailScroll,
                coverage: state.report?.referenceResolutionCoverage ?? [],
                repairCandidates: state.displayedRepairCandidates,
                projectRoot: state.report?.projectRoot,
                on: &canvas
            )
            return
        }
        if state.detailPresentation == .repair {
            renderDetailHeader(
                "Repair proposal · Esc returns to repairs",
                row: row,
                column: column,
                width: width,
                on: &canvas
            )
            renderRepairDetail(
                state,
                row: row + 2,
                column: column,
                width: width,
                height: max(1, height - 2),
                on: &canvas
            )
            return
        }
        switch state.screen {
        case .project:
            renderBrandedRows(
                state,
                row: row,
                column: column,
                width: width,
                height: height,
                on: &canvas
            )
        case .settings where state.settingsSection == .about:
            renderBrandedRows(
                state,
                row: row,
                column: column,
                width: width,
                height: height,
                on: &canvas
            )
        case .findings:
            renderFindings(
                state,
                row: row,
                column: column,
                width: width,
                height: height,
                on: &canvas
            )
        case .repair:
            renderRepairs(
                state,
                row: row,
                column: column,
                width: width,
                height: height,
                on: &canvas
            )
        default:
            renderRows(
                TUIContentRows.rows(for: state),
                selectedIndex: state.contentIndex,
                row: row,
                column: column,
                width: width,
                height: height,
                on: &canvas
            )
        }
    }

    private func renderDetailHeader(
        _ text: String,
        row: Int,
        column: Int,
        width: Int,
        on canvas: inout TerminalCanvas
    ) {
        canvas.write(
            text,
            row: row,
            column: column + 1,
            style: theme.style(
                .secondary,
                highContrast: capabilities.highContrast
            ),
            maximumWidth: max(0, width - 2)
        )
    }
}
