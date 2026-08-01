//===--- TUIScreenRenderer+Chrome.swift - SwiftDelta ------------------------------------------===//
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
    func renderFooter(_ state: TUIState, on canvas: inout TerminalCanvas) {
        let row = canvas.size.rows - 1
        let style = theme.style(
            .header,
            highContrast: capabilities.highContrast
        )
        canvas.fill(
            row: row,
            from: 0,
            width: canvas.size.columns,
            style: style
        )
        let help: String
        if state.settings.interaction.showContextualHelp {
            switch state.screen {
            case .findings:
                help = "↑↓ Select   Enter Inspect   / Search   Esc Home   ? Help"
            case .repair:
                help = "↑↓ Select   Space Choose   Enter Inspect   Esc Home   ? Help"
            case .project:
                help = "↑↓ Select   Enter Open   Space Toggle   ? Help"
            case .setup:
                help = "↑↓ Select   Enter Edit   r Automatic   Esc Home   ? Help"
            default:
                help = "↑↓ Select   Enter Open   Space Toggle   Esc Home   ? Help"
            }
        } else {
            help = "? Help    q Quit"
        }
        canvas.write(
            help,
            row: row,
            column: 1,
            style: style,
            maximumWidth: canvas.size.columns - 2
        )
    }

    func renderOperation(_ state: TUIState, on canvas: inout TerminalCanvas) {
        guard case let .running(kind, startedAt) = state.operationStatus else {
            return
        }
        let width = min(88, canvas.size.columns - 6)
        let height = min(15, canvas.size.rows - 4)
        let column = (canvas.size.columns - width) / 2
        let row = canvas.size.rows - height - 2
        let panel = theme.style(
            .normal,
            highContrast: capabilities.highContrast
        )
        for line in 0..<height {
            canvas.fill(
                row: row + line,
                from: column,
                width: width,
                style: panel
            )
        }
        drawSheetBorder(
            row: row,
            column: column,
            width: width,
            height: height,
            on: &canvas
        )
        let currentTime = now()
        let elapsed = max(0, Int(currentTime.timeIntervalSince(startedAt)))
        let tick = Int(currentTime.timeIntervalSince(startedAt) * 3)
        canvas.write(
            "\(kind.title) · \(elapsed / 60):\(String(format: "%02d", elapsed % 60))"
                + (state.operationPaused ? " · Paused after current phase" : ""),
            row: row + 1,
            column: column + 2,
            style: panel,
            maximumWidth: width - 4
        )
        let animation = OperationPixelAnimation.frame(
            for: kind,
            tick: tick,
            capabilities: capabilities
        )
        OperationPixelAnimation.draw(
            animation,
            on: &canvas,
            row: row + 2,
            column: column + 2,
            theme: theme,
            capabilities: capabilities
        )
        let captionColumn = column + 2
            + OperationPixelAnimation.Frame.width
            + 2
        if captionColumn < column + width - 2 {
            canvas.write(
                animation.caption,
                row: row + 3,
                column: captionColumn,
                style: TerminalStyle(
                    foreground: capabilities.highContrast
                        || capabilities.colorMode == .monochrome
                        ? theme.text : DeltaMark.brandColor,
                    background: theme.background,
                    bold: true
                ),
                maximumWidth: max(
                    0,
                    column + width - 2 - captionColumn
                )
            )
        }
        let progressRow = row
            + 2
            + OperationPixelAnimation.Frame.height
        let progress = state.progressLines.suffix(2)
        for (index, line) in progress.enumerated() {
            canvas.write(
                TerminalText.sanitize(line),
                row: progressRow + index,
                column: column + 2,
                style: TerminalStyle(
                    foreground: theme.text,
                    background: theme.background,
                    dim: !capabilities.highContrast
                ),
                maximumWidth: width - 4
            )
        }
        let progressLabelRow = min(
            row + height - 4,
            progressRow + max(1, progress.count)
        )
        canvas.write(
            OperationProgressBar.label(
                for: state.progressMeasurement,
                capabilities: capabilities
            ),
            row: progressLabelRow,
            column: column + 2,
            style: theme.style(
                .secondary,
                highContrast: capabilities.highContrast
            ),
            maximumWidth: width - 4
        )
        let footerRow = row + height - 2
        OperationProgressBar.draw(
            measurement: state.progressMeasurement,
            tick: tick,
            on: &canvas,
            row: progressLabelRow + 1,
            column: column + 2,
            width: width - 4,
            theme: theme,
            capabilities: capabilities
        )
        canvas.write(
            kind == .planRepair
                ? "p \(state.operationPaused ? "resume" : "pause")   Esc cancel   l details"
                : "Esc cancel   l details",
            row: footerRow,
            column: column + 2,
            style: panel,
            maximumWidth: width - 4
        )
    }

    func renderOverlay(_ state: TUIState, on canvas: inout TerminalCanvas) {
        guard state.overlay != .none else { return }
        let width = min(
            112,
            max(48, min(canvas.size.columns - 6, canvas.size.columns * 4 / 5))
        )
        let height = min(
            34,
            max(12, min(canvas.size.rows - 4, canvas.size.rows * 3 / 4))
        )
        let column = (canvas.size.columns - width) / 2
        let row = (canvas.size.rows - height) / 2
        let panel = theme.style(
            .normal,
            highContrast: capabilities.highContrast
        )
        for line in 0..<height {
            canvas.fill(
                row: row + line,
                from: column,
                width: width,
                style: panel
            )
        }
        drawSheetBorder(
            row: row,
            column: column,
            width: width,
            height: height,
            on: &canvas
        )
        let title: String
        let lines: [String]
        switch state.overlay {
        case let .textInput(inputTitle, _, value):
            title = inputTitle
            lines = [value + "▏"]
        case let .requiredInput(input):
            title = input.title
            lines = [
                input.message,
                "",
                input.value + "▏",
            ] + (
                input.validationMessage.map {
                    ["", "Check: \($0)"]
                } ?? []
            )
        case let .confirmation(confirmTitle, message, _):
            title = confirmTitle
            lines = [message]
        case let .message(messageTitle, message, details):
            title = messageTitle
            lines = [message, ""] + (details?.components(
                separatedBy: .newlines
            ) ?? [])
        case .shortcuts:
            title = "Keyboard controls"
            lines = [
                "Arrow keys       Navigate lists and values",
                "Enter            Open or activate",
                "Space            Toggle or select a repair",
                "Tab / Shift-Tab  Move focus",
                "/                Search findings",
                "g / s / f        Group, sort, or filter findings",
                "Page Up / Down   Scroll details",
                "l                Open technical details",
                "Esc              Back, close, or request cancellation",
                "q                Quit with confirmation",
            ]
        case .logs:
            title = "Operation details"
            lines = state.technicalLog.isEmpty
                ? ["No detailed operation messages in this session."]
                : Array(state.technicalLog.suffix(height * 2))
        case let .setupResolution(resolution):
            renderSetupResolution(
                resolution,
                row: row,
                column: column,
                width: width,
                height: height,
                panel: panel,
                on: &canvas
            )
            return
        case let .draftEditor(editor):
            renderDraftEditor(
                editor,
                row: row,
                column: column,
                width: width,
                height: height,
                panel: panel,
                on: &canvas
            )
            return
        case .none:
            return
        }
        canvas.write(
            title,
            row: row + 1,
            column: column + 2,
            style: theme.style(
                .header,
                highContrast: capabilities.highContrast
            ),
            maximumWidth: width - 4
        )
        let scrollable: Bool
        switch state.overlay {
        case .message, .shortcuts, .logs:
            scrollable = true
        default:
            scrollable = false
        }
        drawWrapped(
            lines,
            row: row + 3,
            column: column + 2,
            width: width - 4,
            height: height - (scrollable ? 5 : 4),
            scroll: scrollable ? state.detailScroll : 0,
            on: &canvas,
            background: theme.background,
            reverse: false
        )
        if scrollable {
            canvas.write(
                "↑↓ / Page Up/Down scroll   Esc close",
                row: row + height - 1,
                column: column + 2,
                style: theme.style(
                    .secondary,
                    highContrast: capabilities.highContrast
                ),
                maximumWidth: width - 4
            )
        } else if case .textInput = state.overlay {
            renderOverlayActions(
                secondary: "Esc  Cancel",
                primary: "Enter  Accept",
                primaryRole: .primaryAction,
                row: row + height - 2,
                column: column,
                width: width,
                on: &canvas
            )
        } else if case .requiredInput = state.overlay {
            renderOverlayActions(
                secondary: "Esc  Cancel",
                primary: "Enter  Continue",
                primaryRole: .primaryAction,
                row: row + height - 2,
                column: column,
                width: width,
                on: &canvas
            )
        } else if case let .confirmation(_, _, action) = state.overlay {
            let primary = switch action {
            case .applyRepairs: "Apply repairs"
            case .clearCache: "Clear cache"
            case .pruneCache: "Prune cache"
            case .clearHistory: "Clear history"
            case .clearSettings: "Reset settings"
            case .cancelOperation: "Cancel operation"
            case .quit: "Quit"
            }
            let role: TerminalStyleRole = switch action {
            case .cancelOperation: .warning
            case .applyRepairs, .clearCache, .pruneCache, .clearHistory,
                 .clearSettings, .quit: .destructive
            }
            renderOverlayActions(
                secondary: "Esc  Cancel",
                primary: "Enter  \(primary)",
                primaryRole: role,
                row: row + height - 2,
                column: column,
                width: width,
                on: &canvas
            )
        }
    }

    private func renderDraftEditor(
        _ editor: TUIRepairDraftEditor,
        row: Int,
        column: Int,
        width: Int,
        height: Int,
        panel: TerminalStyle,
        on canvas: inout TerminalCanvas
    ) {
        canvas.write(
            "Edit Draft Repair",
            row: row + 1,
            column: column + 2,
            style: theme.style(
                .header,
                highContrast: capabilities.highContrast
            ),
            maximumWidth: width - 4
        )
        guard let edit = editor.selectedEdit else {
            canvas.write(
                "This draft contains no source edit.",
                row: row + 3,
                column: column + 2,
                style: theme.style(
                    .error,
                    highContrast: capabilities.highContrast
                ),
                maximumWidth: width - 4
            )
            return
        }
        let editLabel =
            "Edit \(editor.selectedEditIndex + 1) of \(editor.edits.count) · "
            + "\(edit.operation.rawValue) · \(edit.sourceFileIdentity)"
        canvas.write(
            editLabel,
            row: row + 3,
            column: column + 2,
            style: theme.style(
                .secondary,
                highContrast: capabilities.highContrast
            ),
            maximumWidth: width - 4
        )
        let contentHeight = max(3, height - 13)
        let paneHeight = max(2, contentHeight / 2)
        renderDraftEditorField(
            title: "Original anchor",
            text: edit.originalAnchor,
            focused: editor.field == .originalAnchor,
            cursorOffset: editor.field == .originalAnchor
                ? editor.cursorOffset : nil,
            row: row + 5,
            column: column + 2,
            width: width - 4,
            height: paneHeight,
            panel: panel,
            on: &canvas
        )
        renderDraftEditorField(
            title: edit.operation == .delete
                ? "Proposed source (empty for deletion)"
                : "Proposed source",
            text: edit.proposedSource,
            focused: editor.field == .proposedSource,
            cursorOffset: editor.field == .proposedSource
                ? editor.cursorOffset : nil,
            row: row + 6 + paneHeight,
            column: column + 2,
            width: width - 4,
            height: paneHeight,
            panel: panel,
            on: &canvas
        )
        if !editor.validationProblems.isEmpty {
            canvas.write(
                "Validation: "
                    + editor.validationProblems.joined(separator: " · "),
                row: row + height - 4,
                column: column + 2,
                style: theme.style(
                    .warning,
                    highContrast: capabilities.highContrast
                ),
                maximumWidth: width - 4
            )
        }
        canvas.write(
            "Tab field   PgUp/PgDn edit   arrows move   Enter newline",
            row: row + height - 2,
            column: column + 2,
            style: theme.style(
                .secondary,
                highContrast: capabilities.highContrast
            ),
            maximumWidth: width - 4
        )
        canvas.write(
            "Ctrl-S Save",
            row: row + height - 2,
            column: max(column + 2, column + width - 23),
            style: theme.style(
                .primaryAction,
                highContrast: capabilities.highContrast
            ),
            maximumWidth: 11
        )
        canvas.write(
            "Esc Cancel",
            row: row + height - 2,
            column: max(column + 2, column + width - 11),
            style: theme.style(
                .secondary,
                highContrast: capabilities.highContrast
            ),
            maximumWidth: 10
        )
    }

    private func renderDraftEditorField(
        title: String,
        text: String,
        focused: Bool,
        cursorOffset: Int?,
        row: Int,
        column: Int,
        width: Int,
        height: Int,
        panel: TerminalStyle,
        on canvas: inout TerminalCanvas
    ) {
        let titleStyle = theme.style(
            focused ? .primaryAction : .secondary,
            highContrast: capabilities.highContrast
        )
        canvas.write(
            focused ? "[ \(title) ]" : title,
            row: row,
            column: column,
            style: titleStyle,
            maximumWidth: width
        )
        var display = text
        if let cursorOffset {
            let characters = Array(display)
            let position = min(
                max(0, cursorOffset),
                characters.count
            )
            var withCursor = characters
            withCursor.insert("▏", at: position)
            display = String(withCursor)
        }
        drawWrapped(
            display.isEmpty ? [""] : display.components(
                separatedBy: .newlines
            ),
            row: row + 1,
            column: column,
            width: width,
            height: max(1, height - 1),
            scroll: 0,
            on: &canvas,
            background: theme.background,
            reverse: false
        )
    }

    private func renderOverlayActions(
        secondary: String,
        primary: String,
        primaryRole: TerminalStyleRole,
        row: Int,
        column: Int,
        width: Int,
        on canvas: inout TerminalCanvas
    ) {
        canvas.write(
            secondary,
            row: row,
            column: column + 2,
            style: theme.style(
                .secondary,
                highContrast: capabilities.highContrast
            ),
            maximumWidth: max(0, width / 2 - 3)
        )
        let actionText = "[ \(primary) ]"
        let selectionRole: TerminalSelectionRole = switch primaryRole {
        case .destructive, .error: .destructive
        case .warning: .warning
        case .disabled: .disabled
        default: .primary
        }
        let actionStyle = theme.selectionStyle(
            selectionRole,
            capabilities: capabilities
        )
        let actionRegionStart = column + width / 2
        canvas.fill(
            row: row,
            from: actionRegionStart,
            width: max(0, column + width - 1 - actionRegionStart),
            style: actionStyle
        )
        canvas.write(
            actionText,
            row: row,
            column: max(
                column + width / 2,
                column + width - TerminalText.displayWidth(actionText) - 2
            ),
            style: actionStyle,
            maximumWidth: max(0, width / 2 - 2)
        )
    }

    private func renderSetupResolution(
        _ resolution: TUISetupResolution,
        row: Int,
        column: Int,
        width: Int,
        height: Int,
        panel: TerminalStyle,
        on canvas: inout TerminalCanvas
    ) {
        canvas.write(
            resolution.title,
            row: row + 1,
            column: column + 2,
            style: theme.style(
                .header,
                highContrast: capabilities.highContrast
            ),
            maximumWidth: width - 4
        )
        drawWrapped(
            [resolution.message],
            row: row + 3,
            column: column + 2,
            width: width - 4,
            height: 2,
            scroll: 0,
            on: &canvas,
            background: theme.background,
            reverse: false
        )
        let listRow = row + 6
        let footerSpace = resolution.showsTechnicalDetails ? 7 : 3
        let availableLines = max(2, height - (listRow - row) - footerSpace)
        let available = max(1, availableLines / 2)
        let selected = min(
            max(0, resolution.selectedIndex),
            max(0, resolution.choices.count - 1)
        )
        let start = min(
            max(0, selected - available / 2),
            max(0, resolution.choices.count - available)
        )
        for offset in 0..<available {
            let index = start + offset
            guard resolution.choices.indices.contains(index) else { break }
            let choice = resolution.choices[index]
            let marker = choice.recommended ? " · Recommended" : ""
            let isSelected = index == selected
            let selectedStyle = isSelected
                ? theme.selectionStyle(
                    choice.enabled ? .normal : .disabled,
                    capabilities: capabilities
                )
                : (choice.enabled ? panel : theme.style(
                    .secondary,
                    highContrast: capabilities.highContrast
                ))
            if isSelected {
                for selectedRow in 0...1 {
                    canvas.fill(
                        row: listRow + offset * 2 + selectedRow,
                        from: column + 1,
                        width: width - 2,
                        style: selectedStyle
                    )
                }
            }
            canvas.write(
                "  \(choice.label)\(marker)",
                row: listRow + offset * 2,
                column: column + 2,
                style: selectedStyle,
                maximumWidth: width - 4
            )
            canvas.write(
                "  \(choice.detail)",
                row: listRow + offset * 2 + 1,
                column: column + 2,
                style: isSelected
                    ? selectedStyle
                    : (choice.enabled ? panel : theme.style(
                        .secondary,
                        highContrast: capabilities.highContrast
                    )),
                maximumWidth: width - 4
            )
        }
        if resolution.showsTechnicalDetails {
            let dividerRow = row + height - 6
            canvas.write(
                "Technical details",
                row: dividerRow,
                column: column + 2,
                style: theme.style(
                    .secondary,
                    highContrast: capabilities.highContrast
                ),
                maximumWidth: width - 4
            )
            drawWrapped(
                [resolution.technicalDetails ?? "No additional details."],
                row: dividerRow + 1,
                column: column + 2,
                width: width - 4,
                height: 3,
                scroll: 0,
                on: &canvas,
                background: theme.background,
                reverse: false
            )
        }
        canvas.write(
            "↑↓ Select   d Details   Esc Close",
            row: row + height - 1,
            column: column + 2,
            style: theme.style(
                .secondary,
                highContrast: capabilities.highContrast
            ),
            maximumWidth: max(0, width / 2)
        )
        let selectedChoiceEnabled = resolution.choices.indices.contains(selected)
            && resolution.choices[selected].enabled
        let confirm = selectedChoiceEnabled
            ? "[ Enter  Use choice ]" : "[- Enter  Use choice -]"
        canvas.write(
            confirm,
            row: row + height - 1,
            column: max(
                column + width / 2,
                column + width - TerminalText.displayWidth(confirm) - 2
            ),
            style: theme.style(
                selectedChoiceEnabled ? .primaryAction : .disabled,
                highContrast: capabilities.highContrast
            ),
            maximumWidth: max(0, width / 2 - 2)
        )
    }

    private func drawSheetBorder(
        row: Int,
        column: Int,
        width: Int,
        height: Int,
        on canvas: inout TerminalCanvas
    ) {
        guard width >= 2, height >= 2 else { return }
        let ascii = capabilities.symbolMode == .ascii
        let horizontal = ascii ? "-" : "─"
        let vertical = ascii ? "|" : "│"
        let topLeft = ascii ? "+" : "┌"
        let topRight = ascii ? "+" : "┐"
        let bottomLeft = ascii ? "+" : "└"
        let bottomRight = ascii ? "+" : "┘"
        let style = theme.style(
            .secondary,
            highContrast: capabilities.highContrast
        )
        canvas.write(
            topLeft + String(repeating: horizontal, count: width - 2) + topRight,
            row: row,
            column: column,
            style: style,
            maximumWidth: width
        )
        canvas.write(
            bottomLeft + String(repeating: horizontal, count: width - 2)
                + bottomRight,
            row: row + height - 1,
            column: column,
            style: style,
            maximumWidth: width
        )
        for line in 1..<(height - 1) {
            canvas.write(
                vertical,
                row: row + line,
                column: column,
                style: style,
                maximumWidth: 1
            )
            canvas.write(
                vertical,
                row: row + line,
                column: column + width - 1,
                style: style,
                maximumWidth: 1
            )
        }
    }

    func renderMinimumSize(
        _ state: TUIState,
        on canvas: inout TerminalCanvas
    ) {
        let style = theme.style(
            .normal,
            highContrast: capabilities.highContrast
        )
        let required = TerminalSize.minimum
        let lines = [
            "SwiftDelta needs a larger terminal.",
            "Current: \(canvas.size.columns) × \(canvas.size.rows)",
            "Minimum: \(required.columns) × \(required.rows)",
            "Resize the window, or press q to quit.",
        ]
        for (index, line) in lines.enumerated() where index < canvas.size.rows {
            canvas.write(
                line,
                row: index,
                column: 0,
                style: style,
                maximumWidth: canvas.size.columns
            )
        }
        _ = state
    }

}
