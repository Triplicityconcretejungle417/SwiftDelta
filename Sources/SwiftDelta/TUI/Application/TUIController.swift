//===--- TUIController.swift - SwiftDelta ------------------------------------------===//
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

final class TUIController {
    var state: TUIState
    let settingsStore: TUISettingsStore
    let coordinator: TUIOperationCoordinator
    private let monotonicTime: @Sendable () -> TimeInterval
    private let foundationModelStatusProvider:
        @Sendable () -> OnDeviceFoundationModelStatus
    private var lastMouseSelection: (
        screen: TUIScreen,
        index: Int,
        time: TimeInterval
    )?
    private var lastSetupChoiceSelection: (
        field: TUISetupField,
        index: Int,
        time: TimeInterval
    )?

    init(
        state: TUIState,
        settingsStore: TUISettingsStore,
        coordinator: TUIOperationCoordinator,
        monotonicTime: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        foundationModelStatusProvider:
            @escaping @Sendable () -> OnDeviceFoundationModelStatus = {
                .unavailable
        }
    ) {
        self.state = state
        self.settingsStore = settingsStore
        self.coordinator = coordinator
        self.monotonicTime = monotonicTime
        self.foundationModelStatusProvider = foundationModelStatusProvider
        self.state.navigationIndex = self.state.navigationScreens.firstIndex(
            of: self.state.screen
        ) ?? 0
    }

    func registerMouseSelection() -> Bool {
        let time = monotonicTime()
        let current = (state.screen, state.contentIndex)
        let isDoubleClick = lastMouseSelection.map {
            $0.screen == current.0
                && $0.index == current.1
                && time >= $0.time
                && time - $0.time <= 0.45
        } ?? false
        lastMouseSelection = isDoubleClick
            ? nil
            : (current.0, current.1, time)
        return isDoubleClick
    }

    func clearMouseSelection() {
        lastMouseSelection = nil
        lastSetupChoiceSelection = nil
    }

    func refreshFoundationModelStatus() {
        state.foundationModelStatus = foundationModelStatusProvider()
    }

    func registerSetupChoiceSelection(
        field: TUISetupField,
        index: Int
    ) -> Bool {
        let time = monotonicTime()
        let isDoubleClick = lastSetupChoiceSelection.map {
            $0.field == field
                && $0.index == index
                && time >= $0.time
                && time - $0.time <= 0.45
        } ?? false
        lastSetupChoiceSelection = isDoubleClick
            ? nil : (field, index, time)
        return isDoubleClick
    }

    func handleResize(_ size: TerminalSize) {
        clearMouseSelection()
        if TUILayoutMode(columns: size.columns) != .wide,
           state.focus == .details,
           state.detailPresentation == .none
        {
            state.focus = .content
        }
        state.contentIndex = min(
            max(0, state.contentIndex),
            max(0, contentCount - 1)
        )
    }

    var capabilities: TerminalCapabilities {
        var detected = TerminalCapabilities.detect()
        if let color = state.settings.appearance.colorMode {
            detected.colorMode = color
        }
        if let symbols = state.settings.appearance.symbolMode {
            detected.symbolMode = symbols
        }
        detected.highContrast = state.settings.appearance.highContrast
        detected.reducedMotion = state.settings.appearance.reducedMotion
        return detected
    }

    func handle(_ key: TUIKey, terminalSize: TerminalSize) {
        if case .mouse = key {
            // Mouse selection state is retained only for double-click detection.
        } else {
            clearMouseSelection()
        }
        if state.overlay != .none {
            handleOverlay(key, terminalSize: terminalSize)
            return
        }
        if case .running(.planRepair, _) = state.operationStatus,
           key == .character("p")
        {
            state.operationPaused = coordinator.togglePause()
            return
        }
        switch key {
        case .terminate:
            coordinator.cancel()
            state.shouldQuit = true
            return
        case .interrupt:
            if coordinator.isRunning() {
                coordinator.cancel()
            } else {
                state.shouldQuit = true
            }
            return
        case .escape:
            if state.detailPresentation != .none {
                state.detailPresentation = .none
                state.focus = .content
                state.detailScroll = 0
                state.horizontalScroll = 0
                return
            }
            if coordinator.isRunning() {
                state.overlay = .confirmation(
                    title: "Cancel operation?",
                    message:
                        "Active child processes will stop and temporary artifacts will be cleaned.",
                    action: .cancelOperation
                )
            } else {
                switch state.screen {
                case .project:
                    break
                case .setup, .check, .findings, .repair, .settings:
                    selectScreen(.project)
                }
            }
            return
        case .character("q"):
            state.overlay = .confirmation(
                title: "Quit SwiftDelta?",
                message: coordinator.isRunning()
                    ? "The active operation will be cancelled before exit."
                    : "The analyzed project will not be changed.",
                action: .quit
            )
            return
        case .character("?"):
            state.overlay = .shortcuts
            return
        case .character("l"):
            state.detailScroll = 0
            state.overlay = .logs
            return
        case .tab:
            cycleFocus(forward: true, terminalSize: terminalSize)
            return
        case .backTab:
            cycleFocus(forward: false, terminalSize: terminalSize)
            return
        default:
            break
        }

        if state.screen == .findings {
            switch key {
            case .character("/"):
                state.overlay = .textInput(
                    title: "Search findings",
                    field: .search,
                    value: state.search
                )
                return
            case .character("g"):
                state.grouping = next(
                    state.grouping,
                    in: FindingGrouping.allCases
                )
                return
            case .character("s"):
                state.sorting = next(
                    state.sorting,
                    in: FindingSort.allCases
                )
                state.contentIndex = 0
                return
            case .character("f"):
                let values: [Severity?] = [nil, .error, .warning, .notice]
                state.severityFilter = nextOptional(
                    state.severityFilter,
                    in: values
                )
                state.contentIndex = 0
                return
            default:
                break
            }
        }
        if state.screen == .setup, key == .character("r") {
            let rows = TUIContentRows.rows(for: state)
            if rows.indices.contains(state.contentIndex),
               case let .edit(field) = rows[state.contentIndex].action,
               let setupField = field.setupField
            {
                resetAutomaticSelection(setupField)
            }
            return
        }

        switch state.focus {
        case .navigation:
            handleNavigation(key)
        case .content:
            handleContent(key)
        case .details:
            handleDetails(key)
        }
        if case let .mouse(event) = key {
            handleMouse(event, terminalSize: terminalSize)
        }
    }

    func consumeOperationEvents() {
        for event in coordinator.drainEvents() {
            switch event {
            case let .started(kind, date):
                state.operationStatus = .running(kind, startedAt: date)
                state.operationPaused = false
                state.progressLines = []
                state.progressMeasurement = nil
                appendLog("Started \(kind.title)")
            case let .progress(.message(text)):
                let lines = text.split(whereSeparator: \.isNewline).map(
                    String.init
                )
                for line in lines {
                    let clean = TerminalText.sanitize(line)
                    state.progressLines.append(clean)
                    appendLog(clean)
                }
                if state.progressLines.count > 12 {
                    state.progressLines.removeFirst(
                        state.progressLines.count - 12
                    )
                }
            case let .progress(.measurement(measurement)):
                state.progressMeasurement = measurement
            case let .completed(kind, result):
                accept(result)
                let message = completionMessage(kind, result: result)
                state.operationStatus = .succeeded(kind, message: message)
                state.operationPaused = false
                state.progressMeasurement = nil
                appendLog(message)
                recordHistory(operation: kind.title, outcome: "succeeded")
            case let .failed(kind, summary, details):
                if kind == .automaticSetup {
                    state.pendingOperation = nil
                }
                let cleanSummary = TerminalText.sanitize(summary)
                let cleanDetails = TerminalText.sanitize(
                    details,
                    preservingNewlines: true
                )
                if kind == .validateRepair,
                   let candidateID = state.validatingRepairCandidateID
                {
                    state.repairValidationMessages[candidateID] =
                        cleanDetails.isEmpty ? cleanSummary : cleanDetails
                    state.validatingRepairCandidateID = nil
                }
                state.operationStatus = .failed(
                    kind,
                    summary: cleanSummary,
                    details: cleanDetails
                )
                state.operationPaused = false
                state.progressMeasurement = nil
                appendLog("Failed \(kind.title): \(cleanSummary)")
                appendLog(cleanDetails)
                state.overlay = .message(
                    title: "\(kind.title) failed",
                    message: cleanSummary,
                    details:
                        "Review Project setup or open operation details with l.\n"
                        + cleanDetails
                )
                recordHistory(operation: kind.title, outcome: "failed")
            case let .cancelled(kind):
                if kind == .automaticSetup {
                    state.pendingOperation = nil
                }
                state.operationStatus = .cancelled(kind)
                state.operationPaused = false
                if kind == .validateRepair {
                    state.validatingRepairCandidateID = nil
                }
                state.progressMeasurement = nil
                appendLog("Cancelled \(kind.title)")
                recordHistory(operation: kind.title, outcome: "cancelled")
            }
        }
        if !coordinator.isRunning(),
           state.overlay == .none,
           let pending = state.pendingOperation,
           pending != .automaticSetup
        {
            state.pendingOperation = nil
            start(pending)
        }
    }

    func cancelAndWaitForExit() {
        coordinator.cancel()
        _ = coordinator.waitUntilIdle(timeout: 5)
    }
}
